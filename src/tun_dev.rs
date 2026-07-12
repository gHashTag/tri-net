//! Linux `/dev/net/tun` device wrapper — thin syscall plumbing (L6-allowed).
//!
//! Uses constants from the t27-generated `tun_device` module. This file contains
//! NO business logic: it only opens the TUN device, configures it via ioctl, and
//! provides read/write for IP packets. The routing decision (which mesh node to
//! send to) lives in `router.rs`; the TUN↔router wiring lives in the daemon.
//!
//! Platform: Linux only (`CONFIG_TUN=y` in kernel). On macOS this module exists
//! but `TunDevice::open()` returns an error — tests use a `MockTun` instead.

#[allow(unused_imports)]
use crate::tun_device;
use std::io;
#[allow(unused_imports)]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

#[cfg(target_os = "linux")]
use std::ffi::CString;

/// A TUN device handle: an open file descriptor to `/dev/net/tun` configured
/// with IFF_TUN | IFF_NO_PI.
pub struct TunDevice {
    fd: OwnedFd,
    name: String,
}

/// Errors from TUN device operations.
#[derive(Debug)]
pub enum TunError {
    /// `/dev/net/tun` not available (kernel lacks CONFIG_TUN=y on Linux,
    /// or running on a non-Linux platform).
    NotAvailable,
    /// ioctl(TUNSETIFF) failed — usually means the interface name is too long
    /// or already in use.
    IoctlFailed(i32),
    /// read/write I/O error.
    Io(io::Error),
}

impl From<io::Error> for TunError {
    fn from(e: io::Error) -> Self {
        TunError::Io(e)
    }
}

impl std::fmt::Display for TunError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TunError::NotAvailable => write!(f, "TUN device not available (CONFIG_TUN not set?)"),
            TunError::IoctlFailed(errno) => write!(f, "TUNSETIFF ioctl failed (errno {})", errno),
            TunError::Io(e) => write!(f, "TUN I/O error: {}", e),
        }
    }
}

impl std::error::Error for TunError {}

/// Build the `ifreq` struct for TUNSETIFF ioctl.
/// Layout: [ifr_name: 16 bytes][ifr_flags: 2 bytes][padding: 22 bytes] = 40 bytes total.
/// ifr_name is the interface name (e.g. "tritun0") NUL-padded to 16 bytes.
#[cfg(target_os = "linux")]
fn build_ifreq(name: &str) -> io::Result<[u8; 40]> {
    let mut ifr = [0u8; 40];
    let name_bytes = name.as_bytes();
    if name_bytes.len() >= tun_device::IFNAMSIZ as usize {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("interface name '{}' too long (max {})", name, tun_device::IFNAMSIZ - 1),
        ));
    }
    // Copy name into ifr_name field (bytes 0..15), NUL-terminated
    ifr[..name_bytes.len()].copy_from_slice(name_bytes);
    // Set ifr_flags = IFF_TUN | IFF_NO_PI at byte offset 16
    let flags = tun_device::tun_flags_no_pi() as u16;
    ifr[16] = (flags & 0xFF) as u8;
    ifr[17] = (flags >> 8) as u8;
    Ok(ifr)
}

impl TunDevice {
    /// Open `/dev/net/tun` and configure it as a TUN device with IFF_NO_PI.
    /// Returns a handle for reading/writing raw IP packets.
    ///
    /// After opening, the caller must configure the interface address and bring
    /// it up (e.g. `ip addr add 10.42.0.N/24 dev tritun0 && ip link set tritun0 up`).
    #[cfg(target_os = "linux")]
    pub fn open(name: &str) -> Result<Self, TunError> {
        use libc::{c_int, close, open as c_open, ioctl, O_RDWR};

        let path = CString::new("/dev/net/tun").unwrap();
        unsafe {
            let fd: c_int = c_open(path.as_ptr(), O_RDWR);
            if fd < 0 {
                return Err(TunError::NotAvailable);
            }

            let ifr = build_ifreq(name)?;
            let ret: c_int = ioctl(fd, tun_device::TUNSETIFF as _, ifr.as_ptr() as _);
            if ret < 0 {
                let errno = *libc::__errno_location();
                close(fd);
                return Err(TunError::IoctlFailed(errno));
            }

            // Read back the actual interface name (kernel may have assigned one)
            let actual_name = {
                let name_bytes = &ifr[0..16];
                let nul_pos = name_bytes.iter().position(|&b| b == 0).unwrap_or(16);
                String::from_utf8_lossy(&name_bytes[..nul_pos]).into_owned()
            };

            let owned = OwnedFd::from_raw_fd(fd);
            Ok(TunDevice { fd: owned, name: actual_name })
        }
    }

    /// On non-Linux platforms, TUN is not available.
    #[cfg(not(target_os = "linux"))]
    pub fn open(_name: &str) -> Result<Self, TunError> {
        Err(TunError::NotAvailable)
    }

    /// The kernel-assigned interface name (e.g. "tritun0").
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Read one IP packet from the TUN device into `buf`.
    /// Returns the number of bytes read.
    /// With IFF_NO_PI, the packet starts at byte 0 (no prefix).
    #[cfg(target_os = "linux")]
    pub fn read_packet(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        // SAFETY: self.fd is a valid open TUN file descriptor.
        let n = unsafe {
            libc::read(
                self.fd.as_raw_fd(),
                buf.as_mut_ptr() as *mut _,
                buf.len(),
            )
        };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(n as usize)
        }
    }

    /// Read one IP packet — stub on non-Linux (MockTun is used instead).
    #[cfg(not(target_os = "linux"))]
    pub fn read_packet(&mut self, _buf: &mut [u8]) -> io::Result<usize> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "TUN read not available on this platform"))
    }

    /// Write one IP packet to the TUN device (delivered locally).
    /// With IFF_NO_PI, `pkt` should be the raw IP packet with no prefix.
    #[cfg(target_os = "linux")]
    pub fn write_packet(&mut self, pkt: &[u8]) -> io::Result<usize> {
        // SAFETY: self.fd is a valid open TUN file descriptor.
        let n = unsafe {
            libc::write(
                self.fd.as_raw_fd(),
                pkt.as_ptr() as *const _,
                pkt.len(),
            )
        };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(n as usize)
        }
    }

    /// Write one IP packet — stub on non-Linux (MockTun is used instead).
    #[cfg(not(target_os = "linux"))]
    pub fn write_packet(&mut self, _pkt: &[u8]) -> io::Result<usize> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "TUN write not available on this platform"))
    }

    /// Configure the interface: set IP address and bring it up.
    /// This shells out to `ip` command — simplest approach that works on
    /// embedded Linux without requiring netlink bindings.
    pub fn configure(&self, ip_addr: &str) -> io::Result<()> {
        let name = &self.name;
        std::process::Command::new("ip")
            .args(["addr", "add", ip_addr, "dev", name])
            .output()?;
        std::process::Command::new("ip")
            .args(["link", "set", name, "up"])
            .output()?;
        Ok(())
    }
}

/// A mock TUN device for testing — no real fd, just an in-memory buffer.
/// Implements the same read/write interface as `TunDevice`.
pub struct MockTun {
    pub tx_buf: std::sync::Arc<std::sync::Mutex<Vec<Vec<u8>>>>,
    pub rx_buf: std::sync::Arc<std::sync::Mutex<std::collections::VecDeque<Vec<u8>>>>,
}

impl MockTun {
    pub fn new() -> Self {
        MockTun {
            tx_buf: std::sync::Arc::new(std::sync::Mutex::new(Vec::new())),
            rx_buf: std::sync::Arc::new(std::sync::Mutex::new(std::collections::VecDeque::new())),
        }
    }

    /// Queue a packet for the read side to consume (simulates incoming from kernel).
    pub fn inject_rx(&self, pkt: &[u8]) {
        self.rx_buf.lock().unwrap().push_back(pkt.to_vec());
    }

    /// Read a packet (returns WouldBlock if empty).
    pub fn read_packet(&self, buf: &mut [u8]) -> io::Result<usize> {
        let mut rx = self.rx_buf.lock().unwrap();
        match rx.pop_front() {
            Some(pkt) => {
                let n = pkt.len().min(buf.len());
                buf[..n].copy_from_slice(&pkt[..n]);
                Ok(n)
            }
            None => Err(io::Error::new(io::ErrorKind::WouldBlock, "empty")),
        }
    }

    /// Write a packet (captures it for test assertions).
    pub fn write_packet(&self, pkt: &[u8]) -> io::Result<usize> {
        self.tx_buf.lock().unwrap().push(pkt.to_vec());
        Ok(pkt.len())
    }

    /// Get all packets written to the TUN (delivered locally).
    pub fn delivered(&self) -> Vec<Vec<u8>> {
        self.tx_buf.lock().unwrap().clone()
    }
}

impl Default for MockTun {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mock_tun_roundtrip() {
        let tun = MockTun::new();
        // Inject a fake IP packet (version 4, dst 10.42.0.5)
        let pkt = [0x45, 0, 0, 20, 0, 0, 0, 0, 64, 17, 0, 0, 10, 42, 0, 1, 10, 42, 0, 5];
        tun.inject_rx(&pkt);

        let mut buf = [0u8; 1600];
        let n = tun.read_packet(&mut buf).unwrap();
        assert_eq!(n, 20);
        assert_eq!(&buf[..20], &pkt[..]);

        // Write a response packet
        tun.write_packet(&pkt).unwrap();
        assert_eq!(tun.delivered().len(), 1);
    }

    #[test]
    fn mock_tun_empty_returns_wouldblock() {
        let tun = MockTun::new();
        let mut buf = [0u8; 1600];
        assert!(tun.read_packet(&mut buf).is_err());
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn ifreq_layout() {
        let ifr = build_ifreq("tritun0").unwrap();
        // Name at offset 0
        assert_eq!(&ifr[0..7], b"tritun0");
        assert_eq!(ifr[7], 0); // NUL terminator
        // Flags at offset 16: IFF_TUN(1) | IFF_NO_PI(0x1000) = 0x1001 (little-endian)
        assert_eq!(ifr[16], 0x01); // low byte
        assert_eq!(ifr[17], 0x10); // high byte
        // Total size = 40
        assert_eq!(ifr.len(), 40);
    }

    #[test]
    #[cfg(not(target_os = "linux"))]
    fn open_fails_on_non_linux() {
        let result = TunDevice::open("tritun0");
        assert!(matches!(result, Err(TunError::NotAvailable)));
    }

    #[test]
    fn tun_device_constants_from_spec() {
        // Verify spec-generated constants are correct
        assert_eq!(tun_device::TUNSETIFF, 0x400454CA);
        assert_eq!(tun_device::IFF_TUN, 0x0001);
        assert_eq!(tun_device::IFF_NO_PI, 0x1000);
        assert_eq!(tun_device::tun_flags_no_pi(), 0x1001);
        assert_eq!(tun_device::IFNAMSIZ, 16);
        assert_eq!(tun_device::IFREQ_FLAGS_OFFSET, 16);
    }

    #[test]
    fn tun_device_ioctl_verification() {
        // The spec verifies that build_ioctl reproduces TUNSETIFF
        assert_eq!(tun_device::expected_tunsetiff(), tun_device::TUNSETIFF);
        assert_eq!(tun_device::expected_tunsetowner(), tun_device::TUNSETOWNER);
    }

    #[test]
    fn tun_device_payload_offset() {
        assert_eq!(tun_device::payload_offset(true), 0);
        assert_eq!(tun_device::payload_offset(false), 4);
    }
}
