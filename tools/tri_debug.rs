use std::process::Command;

fn main() {
    let o = Command::new("/opt/homebrew/bin/sshpass")
        .args(&["-p","analog","-o","StrictHostKeyChecking=no","-o","PubkeyAuthentication=no","-o","ConnectTimeout=5"])
        .arg("root@192.168.1.10")
        .arg("uname -r")
        .output();
    
    match o {
        Ok(o) => {
            println!("exit: {}", o.status);
            println!("stdout: {}", String::from_utf8_lossy(&o.stdout));
            println!("stderr: {}", String::from_utf8_lossy(&o.stderr));
        }
        Err(e) => println!("error: {}", e),
    }
}
