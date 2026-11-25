// Native macOS PTY continuity probe. No listener, GUI, or production state.
#[cfg(target_os="macos")]
fn live_pty_run() -> Result<()> {
    use std::fs::File;
    use std::os::fd::{AsRawFd,FromRawFd};
    use std::os::unix::process::CommandExt;
    use std::process::{Command,Stdio};
    struct ChildGuard(std::process::Child);
    impl Drop for ChildGuard {
        fn drop(&mut self) {
            if matches!(self.0.try_wait(),Ok(Some(_))) {return;}
            // The test child owns a dedicated session/process group.
            unsafe {libc::kill(-(self.0.id() as i32),libc::SIGKILL);}
            if let Err(error)=self.0.wait() {eprintln!("PTY child cleanup: {error}");}
        }
    }
    #[derive(Clone)]
    struct Writer {file:Arc<Mutex<File>>, bytes:Arc<Mutex<Vec<u8>>>, error:Arc<Mutex<Option<String>>>}
    impl Write for Writer {
        fn write(&mut self,data:&[u8])->io::Result<usize> {
            let result=(||->io::Result<()> {
                self.file.lock().map_err(|_|io::Error::other("PTY writer lock"))?.write_all(data)?;
                let mut bytes=self.bytes.lock().map_err(|_|io::Error::other("PTY reply lock"))?;
                if bytes.len()+data.len()>65536 {return Err(io::Error::other("PTY reply bound"));}
                bytes.extend_from_slice(data);Ok(())
            })();
            if let Err(error)=result {
                if let Ok(mut slot)=self.error.lock() {*slot=Some(error.to_string());}
                return Err(error);
            }
            Ok(data.len())
        }
        fn flush(&mut self)->io::Result<()> {Ok(())}
    }
    fn emit(writer:&mut impl Write,value:&Value)->Result<()> {
        serde_json::to_writer(&mut *writer,value)?;writer.write_all(b"\n")?;writer.flush()?;Ok(())
    }
    let mut master=-1;let mut slave=-1;
    let mut size=libc::winsize {ws_row:6,ws_col:20,ws_xpixel:180,ws_ypixel:96};
    // openpty transfers two new descriptors on success; each is immediately owned.
    if unsafe {libc::openpty(&mut master,&mut slave,std::ptr::null_mut(),std::ptr::null_mut(),&mut size)}!=0 {
        return Err(io::Error::last_os_error()).context("open native PTY");
    }
    let mut master=unsafe {File::from_raw_fd(master)};
    let slave=unsafe {File::from_raw_fd(slave)};
    for fd in [master.as_raw_fd(),slave.as_raw_fd()] {
        if unsafe {libc::fcntl(fd,libc::F_SETFD,libc::FD_CLOEXEC)}<0 {return Err(io::Error::last_os_error()).context("PTY close-on-exec");}
    }
    let flags=unsafe {libc::fcntl(master.as_raw_fd(),libc::F_GETFL)};
    if flags<0 || unsafe {libc::fcntl(master.as_raw_fd(),libc::F_SETFL,flags|libc::O_NONBLOCK)}<0 {
        return Err(io::Error::last_os_error()).context("PTY nonblocking master");
    }
    let shell=r#"
stty -echo -icanon min 1 time 0 -onlcr
printf 'BOOT:%s\r\n' "$$"
while IFS= read -r action; do
 case "$action" in
 prepare|after)
   printf '\033[3;7H\033[6n'
   answer=$(dd bs=1 count=6 2>/dev/null | od -An -tx1 | tr -d ' \n')
   printf '\r\nDSR:%s:%s\r\n' "$action" "$answer"
   printf 'PID:%s:%s\r\n' "$action" "$$"
   if [ "$action" = after ]; then printf 'SIZE:'; stty size; fi
   printf 'DONE:%s\r\n' "$action";;
 quit) exit 0;;
 esac
done
"#;
    let slave_fd=slave.as_raw_fd();
    let mut command=Command::new("/bin/sh");
    command.arg("-c").arg(shell).env("TERM","xterm-256color")
        .stdin(Stdio::from(slave.try_clone()?)).stdout(Stdio::from(slave.try_clone()?)).stderr(Stdio::from(slave.try_clone()?));
    // Only async-signal-safe syscalls run between fork and exec.
    unsafe {command.pre_exec(move || {
        if libc::setsid()<0 || libc::ioctl(slave_fd,libc::TIOCSCTTY as libc::c_ulong,0)<0 {return Err(io::Error::last_os_error());}
        Ok(())
    });}
    let mut child=ChildGuard(command.spawn().context("spawn native PTY shell")?);
    drop(slave);
    let pid=child.0.id();
    let replies=Writer {file:Arc::new(Mutex::new(master.try_clone()?)),bytes:Arc::new(Mutex::new(Vec::new())),error:Arc::new(Mutex::new(None))};
    let mut term=Terminal::new(TerminalSize {cols:20,rows:6,pixel_width:180,pixel_height:96,dpi:96},
        Arc::new(Config),"MyTerm-prototype","0",Box::new(replies.clone()));
    term.advance_bytes(b"\x1b]2;\x07");
    let mut events=Vec::<Value>::new();
    let mut output=io::stdout().lock();
    fn receive(master:&mut File,term:&mut Terminal,events:&mut Vec<Value>,output:&mut impl Write,stream:bool,marker:&[u8])->Result<Vec<u8>> {
        let deadline=Instant::now()+Duration::from_secs(5);let mut captured=Vec::new();
        while !captured.windows(marker.len()).any(|w|w==marker) {
            anyhow::ensure!(Instant::now()<deadline,"PTY marker timeout: {}",String::from_utf8_lossy(marker));
            let mut poll=libc::pollfd {fd:master.as_raw_fd(),events:libc::POLLIN,revents:0};
            let ready=unsafe {libc::poll(&mut poll,1,100)};
            if ready<0 {return Err(io::Error::last_os_error()).context("PTY poll");}
            if ready==0 {continue;}
            let mut bytes=[0u8;4096];
            let n=match master.read(&mut bytes) {
                Ok(0)=>bail!("PTY EOF before marker"),Ok(n)=>n,
                Err(error) if error.kind()==io::ErrorKind::WouldBlock=>continue,
                Err(error)=>return Err(error).context("PTY read"),
            };
            anyhow::ensure!(captured.len()+n<=65536 && events.len()<128,"PTY capture bound");
            captured.extend_from_slice(&bytes[..n]);
            term.advance_bytes(&bytes[..n]);
            let sequence=events.len();let event=json!({"data":bytes[..n]});
            events.push(event.clone());
            if stream {emit(output,&json!({"sequence":sequence,"event":event}))?;}
        }
        Ok(captured)
    }
    receive(&mut master,&mut term,&mut events,&mut output,false,b"BOOT:")?;
    replies.file.lock().map_err(|_|anyhow::anyhow!("PTY write lock"))?.write_all(b"prepare\n")?;
    let before=receive(&mut master,&mut term,&mut events,&mut output,false,b"DONE:prepare\r\n")?;
    let cut=events.len()-1;
    let checkpoint=term.prototype_checkpoint(cut)?;
    emit(&mut output,&json!({"checkpoint":checkpoint,"pid":pid,"cut":cut}))?;
    // The harness sends this only after the real native client acknowledges import.
    let mut control=Vec::new();let control_deadline=Instant::now()+Duration::from_secs(5);
    while !control.contains(&b'\n') {
        anyhow::ensure!(Instant::now()<control_deadline && control.len()<4096,"PTY continuation timeout or bound");
        let mut poll=libc::pollfd {fd:0,events:libc::POLLIN,revents:0};
        let ready=unsafe {libc::poll(&mut poll,1,100)};
        if ready<0 {return Err(io::Error::last_os_error()).context("PTY control poll");}
        if ready==0 {continue;}
        let mut bytes=[0u8;1024];
        let count=unsafe {libc::read(0,bytes.as_mut_ptr().cast(),bytes.len())};
        anyhow::ensure!(count>0,"PTY control EOF");control.extend_from_slice(&bytes[..count as usize]);
    }
    anyhow::ensure!(std::str::from_utf8(&control)?.trim()=="continue","PTY continuation acknowledgement missing");
    anyhow::ensure!(child.0.try_wait()?.is_none(),"PTY shell exited during fresh-client import");
    let size=libc::winsize {ws_row:8,ws_col:32,ws_xpixel:288,ws_ypixel:128};
    if unsafe {libc::ioctl(master.as_raw_fd(),libc::TIOCSWINSZ,&size)}<0 {return Err(io::Error::last_os_error()).context("PTY resize");}
    term.resize(TerminalSize {cols:32,rows:8,pixel_width:288,pixel_height:128,dpi:96});
    let sequence=events.len();let event=json!({"resize":[32,8]});events.push(event.clone());
    emit(&mut output,&json!({"sequence":sequence,"event":event}))?;
    replies.file.lock().map_err(|_|anyhow::anyhow!("PTY write lock"))?.write_all(b"after\n")?;
    let after=receive(&mut master,&mut term,&mut events,&mut output,true,b"DONE:after\r\n")?;
    if let Some(error)=replies.error.lock().map_err(|_|anyhow::anyhow!("PTY error lock"))?.clone() {bail!("PTY query writer: {error}");}
    let answer=b"1b5b333b3752";
    anyhow::ensure!(before.windows(answer.len()).any(|w|w==answer) && after.windows(answer.len()).any(|w|w==answer),"PTY cursor response differs");
    let expected=format!("PID:after:{pid}");
    anyhow::ensure!(String::from_utf8_lossy(&after).contains(&expected),"PTY PID changed after import");
    anyhow::ensure!(String::from_utf8_lossy(&after).contains("SIZE:8 32"),"PTY did not receive actual resize");
    let reply_bytes=replies.bytes.lock().map_err(|_|anyhow::anyhow!("PTY reply capture lock"))?.clone();
    anyhow::ensure!(reply_bytes==b"\x1b[3;7R\x1b[3;7R","PTY must have exactly one authoritative responder per query");
    replies.file.lock().map_err(|_|anyhow::anyhow!("PTY write lock"))?.write_all(b"quit\n")?;
    let deadline=Instant::now()+Duration::from_secs(5);
    loop {
        if let Some(status)=child.0.try_wait()? {anyhow::ensure!(status.success(),"PTY child failed");break;}
        anyhow::ensure!(Instant::now()<deadline,"PTY exit timeout");
        std::thread::sleep(Duration::from_millis(10));
    }
    emit(&mut output,&json!({"ptyEvidence":{"pid":pid,"sameShellAfterImport":true,"cut":cut,"events":events,
        "before":before,"after":after,"replyBytes":reply_bytes,"actualResize":[32,8],"childExitedSuccessfully":true}}))?;
    Ok(())
}
