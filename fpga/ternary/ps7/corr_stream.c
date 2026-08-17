/* corr_stream -- push OTA samples through the ternary correlator in the PL and
 * compare against the software reference, bit for bit.
 *
 * This replaces the shell version. A shell loop over forked `devmem` calls is
 * not an instrument: each call is an open/mmap/read/close costing milliseconds,
 * the 20-bit result straddles two GPIO banks and is therefore sampled at two
 * different times, and the ingest counter came back with deltas of 1, 2, 4, 17
 * and 18 across runs of the same 256 samples. Here /dev/mem is opened once, the
 * GPIO block is mapped once, and each sample costs two adjacent 32-bit loads.
 *
 * Build (on any host, for the board's armv7):
 *   arm-linux-gnueabihf-gcc -O2 -static -o corr_stream corr_stream.c
 *
 * Run, on the board, with the PL masters already quiesced and ps7_corr loaded:
 *   ./corr_stream rx_on_raw.hex golden_matched.txt [limit]
 *
 * Exit codes match the shell version:
 *   0 all matched   2 preconditions   3 anchor wrong
 *   4 no ingest     5 at least one value differs
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/mman.h>

#define GPIO_BASE   0xE000A000u
#define MAP_LEN     0x1000u

/* offsets inside the GPIO block (UG585 ch. 14) */
#define OFF_DATA2_O 0x048u   /* bank 2 out -> EMIOGPIOO[31:0]  */
#define OFF_DATA2_I 0x068u   /* bank 2 in  <- EMIOGPIOI[31:0]  */
#define OFF_DATA3_I 0x06Cu   /* bank 3 in  <- EMIOGPIOI[63:32] */
#define OFF_DIRM2   0x284u
#define OFF_OEN2    0x288u

#define ANCHOR      0x47C0u

/* EMIO out: [15:0] sample, [16] strobe, [17] rst, [18] c_wr,
 *           [21:19] c_addr, [23:22] c_data
 * EMIO in : [15:0] anchor, [35:16] corr, [43:36] count, [44] ack          */

static volatile uint32_t *gpio;

static inline void wr(unsigned off, uint32_t v) {
    *(volatile uint32_t *)((volatile uint8_t *)gpio + off) = v;
    __sync_synchronize();
}
static inline uint32_t rd(unsigned off) {
    __sync_synchronize();
    return *(volatile uint32_t *)((volatile uint8_t *)gpio + off);
}

/* One coherent sample of the 64-bit EMIO input word. The two banks are two
 * loads a few nanoseconds apart rather than two processes milliseconds apart;
 * re-read the high half and retry if it moved under us. */
static void read_in(uint32_t *lo, uint32_t *hi) {
    uint32_t h1, l, h2;
    int tries = 0;
    do {
        h1 = rd(OFF_DATA3_I);
        l  = rd(OFF_DATA2_I);
        h2 = rd(OFF_DATA3_I);
    } while (h1 != h2 && ++tries < 8);
    *lo = l;
    *hi = h1;
}

static int32_t corr_of(uint32_t lo, uint32_t hi) {
    uint32_t raw = ((hi & 0xFu) << 16) | ((lo >> 16) & 0xFFFFu);   /* 20 bits */
    return (raw & 0x80000u) ? (int32_t)raw - 0x100000 : (int32_t)raw;
}
static unsigned count_of(uint32_t hi) { return (hi >> 4) & 0xFFu; }

static void load_taps(const int *codes) {
    /* Written twice on purpose. c_wr is edge-detected two flops downstream of
     * an asynchronous PS write and the first transaction after configuration
     * is measurably dropped; the write is idempotent so a duplicate is free. */
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < 8; i++) {
            uint32_t base = ((uint32_t)codes[i] << 22) | ((uint32_t)i << 19);
            wr(OFF_DATA2_O, base);
            wr(OFF_DATA2_O, base | (1u << 18));
            wr(OFF_DATA2_O, base);
        }
    }
}

static size_t load_lines(const char *path, long *out, size_t max, int hex) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char line[64];
    size_t n = 0;
    while (n < max && fgets(line, sizeof line, f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\n' || *p == '\0' || *p == '#') continue;
        out[n++] = hex ? (long)strtoul(p, NULL, 16) : strtol(p, NULL, 10);
    }
    fclose(f);
    return n;
}

int main(int argc, char **argv) {
    const char *sfile = argc > 1 ? argv[1] : "rx_on_raw.hex";
    const char *gfile = argc > 2 ? argv[2] : "golden_matched.txt";
    size_t limit      = argc > 3 ? (size_t)atoi(argv[3]) : 256;
    if (limit == 0 || limit > 65536) limit = 256;

    static long samp[65536], gold[65536];
    size_t ns = load_lines(sfile, samp, limit, 1);
    size_t ng = load_lines(gfile, gold, limit, 0);
    if (!ns || !ng) { fprintf(stderr, "FATAL: cannot read %s / %s\n", sfile, gfile); return 2; }
    if (ng < ns) ns = ng;

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("FATAL: /dev/mem"); return 2; }
    void *m = mmap(NULL, MAP_LEN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, GPIO_BASE);
    if (m == MAP_FAILED) { perror("FATAL: mmap"); close(fd); return 2; }
    gpio = (volatile uint32_t *)m;

    wr(OFF_DIRM2, 0x00FFFFFFu);
    wr(OFF_OEN2,  0x00FFFFFFu);

    uint32_t lo, hi;
    read_in(&lo, &hi);
    printf("anchor: 0x%04X (expected 0x%04X)\n", lo & 0xFFFFu, ANCHOR);
    if ((lo & 0xFFFFu) != ANCHOR) {
        printf("VERDICT: anchor wrong -- this is not our bitstream\n");
        return 3;
    }

    /* matched = 1 1 0 -1 -1 -1 0 1, encoded 01 -> +1, 10 -> -1, else 0 */
    static const int codes[8] = { 1, 1, 0, 2, 2, 2, 0, 1 };
    wr(OFF_DATA2_O, 1u << 17); wr(OFF_DATA2_O, 0);      /* clear delay line */
    load_taps(codes);
    wr(OFF_DATA2_O, 1u << 17); wr(OFF_DATA2_O, 0);      /* taps survive this */

    read_in(&lo, &hi);
    unsigned c0 = count_of(hi);

    /* Pipeline: m_data is registered off s_valid, corr_hold off m_valid, so the
     * value readable after pushing sample n is the correlation through n-1.
     * Compare against the previous golden value and take one extra read. */
    unsigned strobe = 0, fail = 0, checked = 0;
    long first_bad_i = -1, first_bad_got = 0, first_bad_exp = 0;
    int have_prev = 0; long prev_exp = 0;

    for (size_t n = 0; n < ns; n++) {
        uint32_t v = (uint32_t)(samp[n] & 0xFFFFu);
        strobe ^= 1u;
        wr(OFF_DATA2_O, (strobe << 16) | v);
        read_in(&lo, &hi);
        int32_t c = corr_of(lo, hi);
        if (have_prev) {
            checked++;
            if (c != prev_exp) {
                if (!fail) { first_bad_i = (long)n - 1; first_bad_got = c; first_bad_exp = prev_exp; }
                fail++;
            }
        }
        prev_exp = gold[n];
        have_prev = 1;
    }
    /* The last sample's result needs one more strobe to reach corr_hold:
     * m_data latches `corr` computed BEFORE the new sample shifts in, and
     * corr_hold takes m_data one m_valid later. So pushing a throwaway sample
     * makes the correlation through sample ns-1 readable. Without this the
     * final value is simply unobtainable -- it is not a mismatch. */
    strobe ^= 1u;
    wr(OFF_DATA2_O, (strobe << 16) | 0u);
    read_in(&lo, &hi);
    { int32_t c = corr_of(lo, hi);
      checked++;
      if (c != prev_exp) {
          if (!fail) { first_bad_i = (long)ns - 1; first_bad_got = c; first_bad_exp = prev_exp; }
          fail++;
      } }

    read_in(&lo, &hi);
    unsigned c1 = count_of(hi);
    unsigned delta = (c1 - c0) & 0xFFu;
    printf("ingest counter %u -> %u (delta %u, expected %u)\n",
           c0, c1, delta, (unsigned)(ns & 0xFFu));

    if (delta == 0 && ns % 256 != 0 && fail == checked) {
        printf("VERDICT: the fabric ingested nothing\n");
        return 4;
    }
    if (fail) {
        printf("VERDICT: %u of %u differ. first: index %ld fabric=%ld reference=%ld\n",
               fail, checked, first_bad_i, (long)first_bad_got, (long)first_bad_exp);
        return 5;
    }
    printf("=== VERDICT: %u of %u bit-exact against the software reference ===\n", checked, checked);
    printf("The ternary correlator ran in the fabric on real over-the-air samples.\n");
    return 0;
}
