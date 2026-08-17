/* pn_stream -- push OTA samples through the 63-tap PN despreader in the PL and
 * compare against the software reference, bit for bit.
 *
 * Same instrument as corr_stream.c, rebuilt for the wider EMIO map of ps7_pn.
 * The reasons for it being C and not shell are in corr_stream.c and have not
 * changed: forked devmem calls cost milliseconds each and sample the two GPIO
 * banks at two different times, which for a value that straddles them is fatal.
 * Here it matters more, not less: corr is now 24 bits and crosses the bank
 * boundary by a whole byte.
 *
 * Build:  arm-linux-gnueabihf-gcc -O2 -static -o pn_stream pn_stream.c
 *   or:   docker run --platform linux/arm/v7 arm32v7/alpine:3.19 \
 *             sh -c "apk add gcc musl-dev && gcc -O2 -static -o pn_stream pn_stream.c"
 *
 * Run, on the board, PL masters quiesced and ps7_pn_tree loaded:
 *   ./pn_stream rx_on_raw.hex pn_golden.txt pn_taps.txt [limit]
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
#define OFF_DATA2_O 0x048u
#define OFF_DATA2_I 0x068u
#define OFF_DATA3_I 0x06Cu
#define OFF_DIRM2   0x284u
#define OFF_OEN2    0x288u
#define ANCHOR      0x47C0u
#define NTAPS       63

/* EMIO out: [15:0] sample, [16] strobe, [17] rst, [18] c_wr,
 *           [24:19] c_addr (6 bits), [26:25] c_data
 * EMIO in : [15:0] anchor, [39:16] corr (24b), [47:40] count, [48] ack
 *   bank2 = EMIO[31:0], bank3 = EMIO[63:32]
 *   corr  = ((bank3 & 0xFF) << 16) | (bank2 >> 16)      sign-extend from bit 23
 *   count = (bank3 >> 8) & 0xFF
 *   ack   = (bank3 >> 16) & 1                                                */

static volatile uint8_t *gpio;

static inline void wr(unsigned off, uint32_t v) {
    *(volatile uint32_t *)(gpio + off) = v;
    __sync_synchronize();
}
static inline uint32_t rd(unsigned off) {
    __sync_synchronize();
    return *(volatile uint32_t *)(gpio + off);
}

static void read_in(uint32_t *lo, uint32_t *hi) {
    uint32_t h1, l, h2;
    int tries = 0;
    do {
        h1 = rd(OFF_DATA3_I);
        l  = rd(OFF_DATA2_I);
        h2 = rd(OFF_DATA3_I);
    } while (h1 != h2 && ++tries < 8);
    *lo = l; *hi = h1;
}

static int32_t corr_of(uint32_t lo, uint32_t hi) {
    uint32_t raw = ((hi & 0xFFu) << 16) | ((lo >> 16) & 0xFFFFu);   /* 24 bits */
    return (raw & 0x800000u) ? (int32_t)raw - 0x1000000 : (int32_t)raw;
}
static unsigned count_of(uint32_t hi) { return (hi >> 8) & 0xFFu; }

static void load_taps(const int *codes, int n) {
    /* Twice: the first c_wr edge after configuration is measurably dropped
     * (see FIRST_LOAD.md). The write is idempotent, so a duplicate is free. */
    for (int pass = 0; pass < 2; pass++)
        for (int i = 0; i < n; i++) {
            uint32_t base = ((uint32_t)codes[i] << 25) | ((uint32_t)i << 19);
            wr(OFF_DATA2_O, base);
            wr(OFF_DATA2_O, base | (1u << 18));
            wr(OFF_DATA2_O, base);
        }
}

static size_t load_lines(const char *path, long *out, size_t max, int hex) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char line[64]; size_t n = 0;
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
    const char *gfile = argc > 2 ? argv[2] : "pn_golden.txt";
    const char *tfile = argc > 3 ? argv[3] : "pn_taps.txt";
    size_t limit      = argc > 4 ? (size_t)atoi(argv[4]) : 256;
    if (!limit || limit > 65536) limit = 256;

    static long samp[65536], gold[65536], tapl[256];
    size_t ns = load_lines(sfile, samp, limit, 1);
    size_t ng = load_lines(gfile, gold, limit, 0);
    size_t nt = load_lines(tfile, tapl, NTAPS, 0);
    if (!ns || !ng || nt != NTAPS) {
        fprintf(stderr, "FATAL: need %s, %s and %d tap codes in %s (got %zu)\n",
                sfile, gfile, NTAPS, tfile, nt);
        return 2;
    }
    if (ng < ns) ns = ng;
    int codes[NTAPS];
    for (int i = 0; i < NTAPS; i++) codes[i] = (int)tapl[i];

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("FATAL: /dev/mem"); return 2; }
    void *m = mmap(NULL, MAP_LEN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, GPIO_BASE);
    if (m == MAP_FAILED) { perror("FATAL: mmap"); return 2; }
    gpio = (volatile uint8_t *)m;

    wr(OFF_DIRM2, 0x07FFFFFFu);      /* bits 0..26 driven toward the PL */
    wr(OFF_OEN2,  0x07FFFFFFu);

    uint32_t lo, hi;
    read_in(&lo, &hi);
    printf("anchor: 0x%04X (expected 0x%04X)\n", lo & 0xFFFFu, ANCHOR);
    if ((lo & 0xFFFFu) != ANCHOR) { printf("VERDICT: not our bitstream\n"); return 3; }

    wr(OFF_DATA2_O, 1u << 17); wr(OFF_DATA2_O, 0);
    load_taps(codes, NTAPS);
    wr(OFF_DATA2_O, 1u << 17); wr(OFF_DATA2_O, 0);

    read_in(&lo, &hi);
    unsigned c0 = count_of(hi);

    unsigned strobe = 0, fail = 0, checked = 0;
    long bad_i = -1, bad_got = 0, bad_exp = 0;
    int have_prev = 0; long prev_exp = 0;

    for (size_t n = 0; n < ns; n++) {
        strobe ^= 1u;
        wr(OFF_DATA2_O, (strobe << 16) | (uint32_t)(samp[n] & 0xFFFFu));
        read_in(&lo, &hi);
        int32_t c = corr_of(lo, hi);
        if (have_prev) {
            checked++;
            if (c != prev_exp && !fail) { bad_i = (long)n - 1; bad_got = c; bad_exp = prev_exp; }
            if (c != prev_exp) fail++;
        }
        prev_exp = gold[n];
        have_prev = 1;
    }
    /* the last result needs one more strobe to reach corr_hold */
    strobe ^= 1u;
    wr(OFF_DATA2_O, (strobe << 16) | 0u);
    read_in(&lo, &hi);
    {   int32_t c = corr_of(lo, hi);
        checked++;
        if (c != prev_exp && !fail) { bad_i = (long)ns - 1; bad_got = c; bad_exp = prev_exp; }
        if (c != prev_exp) fail++; }

    read_in(&lo, &hi);
    printf("ingest counter %u -> %u (delta %u)\n", c0, count_of(hi),
           (count_of(hi) - c0) & 0xFFu);

    if (fail) {
        printf("VERDICT: %u of %u differ. first: index %ld fabric=%ld reference=%ld\n",
               fail, checked, bad_i, (long)bad_got, (long)bad_exp);
        return 5;
    }
    printf("=== VERDICT: %u of %u bit-exact against the software reference ===\n", checked, checked);
    printf("The 63-tap PN despreader matched the reference on every sample of this vector.\n");
    return 0;
}
