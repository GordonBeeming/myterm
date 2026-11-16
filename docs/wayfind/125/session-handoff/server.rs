//! Disposable single-process native PTY, control and bounded TLS-stream experiment.
use super::{Config, Terminal, TerminalSize};
use anyhow::{bail, ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};
use std::{collections::{HashMap, VecDeque}, fs::File, io::{self, Read, Write},
    net::{TcpListener, TcpStream}, os::{fd::{AsRawFd, FromRawFd}, unix::process::CommandExt},
    process::{Child, Command, Stdio}, sync::{Arc, Mutex}, time::{Duration, Instant}};

const OFFSET: u64 = 14695981039346656037;
fn digest(mut hash: u64, data: &[u8]) -> u64 {
    for byte in data { hash = (hash ^ u64::from(*byte)).wrapping_mul(1099511628211); } hash
}
#[derive(Clone)]
struct ReplyWriter(Arc<Mutex<Writes>>, Arc<Mutex<Option<String>>>);
#[derive(Default)]
struct Writes { frames:VecDeque<Vec<u8>>, offset:usize, bytes:usize }
impl Writes {
    fn enqueue(&mut self, bytes:&[u8]) -> io::Result<()> {
        if self.bytes+bytes.len()>65536 {return Err(io::Error::other("PTY input queue bound"));}
        self.frames.push_back(bytes.to_vec());self.bytes+=bytes.len();Ok(())
    }
    fn flush(&mut self, file:&mut File) -> io::Result<()> {
        for _ in 0..8 {
            let Some(frame)=self.frames.front() else {break;};
            match file.write(&frame[self.offset..]) {
                Ok(0)=>return Err(io::Error::new(io::ErrorKind::WriteZero,"PTY write zero")),
                Ok(n)=>{self.offset+=n;self.bytes-=n;},
                Err(error) if error.kind()==io::ErrorKind::WouldBlock=>break,
                Err(error)=>return Err(error),
            }
            if self.offset==frame.len() {self.frames.pop_front();self.offset=0;}
        }Ok(())
    }
}
impl Write for ReplyWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let result = self.0.lock().map_err(|_| io::Error::other("reply lock"))?.enqueue(bytes);
        if let Err(error) = &result {
            *self.1.lock().map_err(|_| io::Error::other("reply error lock"))? = Some(error.to_string());
        }
        result.map(|_| bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> { Ok(()) }
}
struct Session {
    pty: File, child: Child, term: Terminal, sequence: usize, hash: u64,
    owner: Option<String>, revision: u64, bytes: u64, input_count: usize,
    reply_error: Arc<Mutex<Option<String>>>,
    writes:Arc<Mutex<Writes>>,
    echo_tail:Vec<u8>, echoes:VecDeque<String>, rejected_echoes:usize,
}
impl Drop for Session {
    fn drop(&mut self) {
        if !matches!(self.child.try_wait(), Ok(Some(_))) {
            unsafe { libc::kill(-(self.child.id() as i32), libc::SIGKILL); }
            if let Err(error) = self.child.wait() { eprintln!("workload cleanup: {error}"); }
        }
    }
}
impl Session {
    fn new(config: &Value) -> Result<Self> {
        let mut master = -1; let mut slave = -1;
        let mut size = libc::winsize { ws_row:40, ws_col:120, ws_xpixel:1080, ws_ypixel:640 };
        ensure!(unsafe {libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), std::ptr::null_mut(), &mut size)} == 0,
            "openpty: {}", io::Error::last_os_error());
        let pty = unsafe {File::from_raw_fd(master)};
        let slave = unsafe {File::from_raw_fd(slave)};
        for fd in [pty.as_raw_fd(), slave.as_raw_fd()] {
            ensure!(unsafe {libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC)} >= 0, "close-on-exec");
        }
        let flags = unsafe {libc::fcntl(pty.as_raw_fd(), libc::F_GETFL)};
        ensure!(flags >= 0 && unsafe {libc::fcntl(pty.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK)} >= 0, "nonblocking PTY");
        let slave_fd = slave.as_raw_fd();
        let mut cmd = Command::new(config["python"].as_str().context("python")?);
        cmd.arg(config["workload"].as_str().context("workload")?).env("TERM", "xterm-256color")
            .stdin(Stdio::from(slave.try_clone()?)).stdout(Stdio::from(slave.try_clone()?))
            .stderr(Stdio::from(slave.try_clone()?));
        unsafe {cmd.pre_exec(move || {
            if libc::setsid() < 0 || libc::ioctl(slave_fd, libc::TIOCSCTTY as libc::c_ulong, 0) < 0 {
                return Err(io::Error::last_os_error());
            } Ok(())
        });}
        let child = cmd.spawn()?; drop(slave);
        let reply_error = Arc::new(Mutex::new(None));
        let writes=Arc::new(Mutex::new(Writes::default()));
        let term = Terminal::new(TerminalSize {cols:120, rows:40, pixel_width:1080, pixel_height:640, dpi:96},
            Arc::new(Config), "MyTerm-handoff-prototype", "0", Box::new(ReplyWriter(writes.clone(), reply_error.clone())));
        Ok(Self {pty, child, term, sequence:0, hash:OFFSET, owner:None, revision:0, bytes:0, input_count:0, reply_error,writes,
            echo_tail:Vec::new(),echoes:VecDeque::new(),rejected_echoes:0})
    }
    fn state(&self) -> Value {
        json!({"owner":self.owner,"revision":self.revision,"pid":self.child.id(),"sequence":self.sequence,
            "hash":self.hash.to_string(),"bytes":self.bytes,"inputCount":self.input_count})
    }
    fn checkpoint(&self, session:usize) -> Result<Value> {
        Ok(json!({"kind":"checkpoint","session":session,"checkpoint":B64.encode(self.term.prototype_checkpoint(self.sequence)?),
            "state":self.state()}))
    }
    fn resize(&mut self, cols:usize, rows:usize) -> Result<Value> {
        ensure!((2..=120).contains(&cols) && (1..=40).contains(&rows), "prototype geometry bound");
        let size = libc::winsize {ws_row:rows as u16, ws_col:cols as u16, ws_xpixel:0, ws_ypixel:0};
        ensure!(unsafe {libc::ioctl(self.pty.as_raw_fd(), libc::TIOCSWINSZ, &size)} == 0, "PTY resize");
        self.term.resize(TerminalSize {cols,rows,pixel_width:cols*9,pixel_height:rows*16,dpi:96});
        self.sequence += 1;
        Ok(json!({"kind":"resize","sequence":self.sequence,"cols":cols,"rows":rows,"hash":self.hash.to_string()}))
    }
}
struct Frame { bytes: Vec<u8>, offset:usize, control:bool }
struct Peer {
    socket:TcpStream, tls:rustls::ServerConnection, input:Vec<u8>, output:VecDeque<Frame>, queued:usize,
    client:Option<String>, generation:u64, subscriptions:[bool;2], ready:[bool;2],
    needs_sync:bool, close:bool, high_water:usize, resyncs:usize, wire_bytes:u64, born:Instant,
    committed:bool, expected_generation:u64, sync_tokens:[u64;2],
}
impl Peer {
    fn queue(&mut self, value:Value, limit:usize) -> Result<()> {
        let mut bytes = serde_json::to_vec(&value)?; bytes.push(b'\n');
        ensure!(self.queued + bytes.len() <= limit,
            "per-viewer queue bound: kind={}, encoded_frame_bytes={}, queued_bytes={}, limit_bytes={}",
            value["kind"],bytes.len(),self.queued,limit);
        self.queued += bytes.len(); self.high_water = self.high_water.max(self.queued);
        self.output.push_back(Frame {bytes, offset:0, control:value["kind"]=="ack"}); Ok(())
    }
    fn discard_unstarted(&mut self) {
        // Requests can already have changed the PTY or controller. Their outcomes must survive overflow.
        self.output.retain(|frame|frame.offset>0 || frame.control);
        self.queued=self.output.iter().map(|frame|frame.bytes.len()-frame.offset).sum();
    }
    fn checkpoint(&mut self, session:&Session, sid:usize, limit:usize) -> Result<()> {
        self.sync_tokens[sid]+=1;self.ready[sid]=false;
        let mut value=session.checkpoint(sid)?;value["syncToken"]=json!(self.sync_tokens[sid]);
        self.queue(value,limit)
    }
    fn deliver(&mut self, value:Value, limit:usize) -> Result<()> {
        if self.needs_sync { return Ok(()); }
        let length = serde_json::to_vec(&value)?.len() + 1;
        // Keep room for bounded control acknowledgements while output is congested.
        if self.queued + length > limit.saturating_sub(16384) {
            self.discard_unstarted(); self.needs_sync = true; self.ready = [false;2]; self.resyncs += 1;
        } else { self.queue(value, limit)?; } Ok(())
    }
    fn network(&mut self) -> Result<Vec<Value>> {
        // Limit each peer's work per tick; an absent reader cannot monopolize the actor.
        for _ in 0..8 {
            match self.tls.read_tls(&mut self.socket) {
                Ok(0) => {self.close = true; break;},
                Ok(_) => {self.tls.process_new_packets()?;},
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error.into()),
            }
        }
        let mut bytes = [0u8;16384];
        loop {
            match self.tls.reader().read(&mut bytes) {
                Ok(0) => break,
                Ok(n) => {self.input.extend_from_slice(&bytes[..n]); ensure!(self.input.len()<=131072, "peer input bound");},
                Err(error) if error.kind()==io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error.into()),
            }
        }
        let mut requests = Vec::new();
        while let Some(end) = self.input.iter().position(|byte|*byte==b'\n') {
            ensure!(requests.len()<64, "request batch bound");
            requests.push(serde_json::from_slice(&self.input[..end])?); self.input.drain(..=end);
        }
        for _ in 0..8 {
            if self.tls.wants_write() {
                match self.tls.write_tls(&mut self.socket) {
                    Ok(n) => self.wire_bytes += n as u64,
                    Err(error) if error.kind()==io::ErrorKind::WouldBlock => break,
                    Err(error) => return Err(error.into()),
                }
            }
            if !self.tls.is_handshaking() {
                if let Some(frame)=self.output.front_mut() {
                    match self.tls.writer().write(&frame.bytes[frame.offset..]) {
                        Ok(n) => {frame.offset+=n;self.queued-=n;},
                        Err(error) if error.kind()==io::ErrorKind::WouldBlock => break,
                        Err(error) => return Err(error.into()),
                    }
                    if frame.offset==frame.bytes.len() {self.output.pop_front();}
                }
            }
        }
        Ok(requests)
    }
}
fn broadcast(peers:&mut [Peer], session:usize, value:Value, limit:usize) -> Result<()> {
    for peer in peers {
        if peer.committed && peer.subscriptions[session] {
            let mut value = value.clone(); value["session"] = json!(session); peer.deliver(value,limit)?;
        }
    } Ok(())
}
pub fn run() -> Result<()> {
    let mut boot = String::new(); io::stdin().read_line(&mut boot)?;
    ensure!(boot.len()<=16384,"boot bound"); let config:Value=serde_json::from_str(&boot)?;
    let limit=config["queue"].as_u64().context("queue")? as usize;
    ensure!([262144,1048576,4194304].contains(&limit),"queue candidate");
    let keys=config["clients"].as_object().context("client capabilities")?.clone();
    let cert=rcgen::generate_simple_self_signed(vec!["localhost".into()])?;
    let tls=rustls::ServerConfig::builder().with_no_client_auth().with_single_cert(
        vec![cert.cert.der().clone()], rustls::pki_types::PrivateKeyDer::Pkcs8(cert.signing_key.serialize_der().into()))?;
    let listener=TcpListener::bind("127.0.0.1:0")?; listener.set_nonblocking(true)?;
    let mut sessions=vec![Session::new(&config)?,Session::new(&config)?];
    println!("{}",json!({"port":listener.local_addr()?.port(),"certificate":B64.encode(cert.cert.der()),
        "pids":sessions.iter().map(|s|s.child.id()).collect::<Vec<_>>()})); io::stdout().flush()?;
    let tls=Arc::new(tls);let mut peers:Vec<Peer>=Vec::new();let mut generations=HashMap::<String,u64>::new();
    let mut stopped=false;let start=Instant::now();let mut output_bytes=0u64;let mut max_queue=0usize;let mut resyncs=0usize;let mut wire_bytes=0u64;
    while !stopped {
        ensure!(start.elapsed()<Duration::from_secs(14400),"four-hour disposable lifetime bound");
        while let Ok((socket,_))=listener.accept() {
            if peers.len()>=32 {drop(socket);continue;}
            socket.set_nonblocking(true)?;socket.set_nodelay(true)?;
            let send=65536i32;
            ensure!(unsafe {libc::setsockopt(socket.as_raw_fd(),libc::SOL_SOCKET,libc::SO_SNDBUF,(&send as *const i32).cast(),4)}==0,"socket send bound");
            let mut connection=rustls::ServerConnection::new(tls.clone())?;connection.set_buffer_limit(Some(16384));
            peers.push(Peer {socket,tls:connection,input:Vec::new(),output:VecDeque::new(),queued:0,client:None,
                generation:0,subscriptions:[false;2],ready:[false;2],needs_sync:false,close:false,high_water:0,resyncs:0,wire_bytes:0,born:Instant::now(),
                committed:false,expected_generation:0,sync_tokens:[0;2]});
        }
        for index in 0..sessions.len() {
            let mut events=Vec::new();let session=&mut sessions[index];
            session.writes.lock().map_err(|_|anyhow::anyhow!("PTY queue lock"))?.flush(&mut session.pty)?;
            for _ in 0..8 {
                let mut bytes=[0u8;8192];
                match session.pty.read(&mut bytes) {
                    Ok(0)=>bail!("unexpected PTY EOF"),
                    Ok(n)=>{
                        session.echo_tail.extend_from_slice(&bytes[..n]);
                        while let Some(end)=session.echo_tail.iter().position(|byte|*byte==b'\n') {
                            let line=String::from_utf8_lossy(&session.echo_tail[..end]);
                            if let Some(at)=line.find("ECHO:") {
                                let marker=line[at+5..].split(':').next().unwrap_or("");
                                if ["rejected-input","displaced-input","absent-controller-input","bypassed-native-gate","stress-displaced-input"].contains(&marker) {session.rejected_echoes+=1;}
                                session.echoes.push_back(line[at..].trim().to_owned());
                                if session.echoes.len()>512 {session.echoes.pop_front();}
                            }
                            session.echo_tail.drain(..=end);
                        }
                        if session.echo_tail.len()>16384 {let cut=session.echo_tail.len()-16384;session.echo_tail.drain(..cut);}
                        session.term.advance_bytes(&bytes[..n]);session.sequence+=1;
                        session.hash=digest(session.hash,&bytes[..n]);session.bytes+=n as u64;output_bytes+=n as u64;
                        events.push(json!({"kind":"output","sequence":session.sequence,"data":B64.encode(&bytes[..n]),"hash":session.hash.to_string()}));
                    },
                    Err(error) if error.kind()==io::ErrorKind::WouldBlock=>break,
                    Err(error)=>return Err(error).context("PTY read"),
                }
            }
            if let Some(error)=session.reply_error.lock().map_err(|_|anyhow::anyhow!("reply error lock"))?.take() {bail!("terminal reply failed: {error}");}
            ensure!(session.child.try_wait()?.is_none(),"workload exited");
            for event in events {broadcast(&mut peers,index,event,limit)?;}
        }
        for index in 0..peers.len() {
            if peers[index].committed && peers[index].client.as_ref().and_then(|c|generations.get(c))!=Some(&peers[index].generation) {
                peers[index].close=true;continue;
            }
            let requests=match peers[index].network() {Ok(value)=>value,Err(error)=>{
                eprintln!("peer closed: {error:#}");peers[index].close=true;continue;
            }};
            for request in requests {
                let id=request["id"].clone(); let action=request["action"].as_str().unwrap_or("");
                let result=(||->Result<Value>{
                    let peer=&mut peers[index];
                    if action=="hello" {
                        ensure!(peer.client.is_none(),"already authenticated");
                        let client=request["client"].as_str().context("client")?;
                        ensure!(keys.get(client)==Some(&request["capability"]),"candidate authentication rejected");
                        let current=*generations.get(client).unwrap_or(&0);
                        ensure!(request["expectedGeneration"].as_u64()==Some(current),"stale channel generation");
                        peer.expected_generation=current;peer.client=Some(client.to_owned());
                        return Ok(json!({"candidateAuthenticated":true}));
                    }
                    let client=peer.client.clone().context("hello required")?;
                    if action=="commit" {
                        ensure!(!peer.committed,"channel already committed");
                        ensure!(*generations.get(&client).unwrap_or(&0)==peer.expected_generation,"stale channel commit");
                        peer.generation=peer.expected_generation+1;peer.committed=true;
                        generations.insert(client,peer.generation);
                        return Ok(json!({"generation":peer.generation}));
                    }
                    ensure!(peer.committed,"candidate has not committed");
                    ensure!(generations.get(&client)==Some(&peer.generation),"displaced channel");
                    if action=="status" {
                        return Ok(json!({"sessions":sessions.iter().map(|s| {
                            let mut state=s.state();state["recentWorkloadEchoes"]=json!(s.echoes.iter().rev().take(8).collect::<Vec<_>>());
                            state["rejectedWorkloadEchoes"]=json!(s.rejected_echoes);state
                        }).collect::<Vec<_>>(),
                            "queue":peer.queued,"queueHighWater":max_queue.max(peers.iter().map(|p|p.high_water).max().unwrap_or(0)),
                            "resyncs":resyncs+peers.iter().map(|p|p.resyncs).sum::<usize>(),
                            "viewers":peers.iter().filter(|p|p.committed).map(|p|json!({"client":p.client,"queued":p.queued,"highWater":p.high_water,"resyncs":p.resyncs})).collect::<Vec<_>>(),
                            "outputBytes":output_bytes,"wireBytes":wire_bytes+peers.iter().map(|p|p.wire_bytes).sum::<u64>()}));
                    }
                    if action=="stop" {stopped=true;return Ok(json!({"stopping":true}));}
                    let sid=request["session"].as_u64().context("session")? as usize;ensure!(sid<2,"session bound");
                    if action=="subscribe" {
                        peer.subscriptions[sid]=request["enabled"].as_bool().context("enabled")?;peer.ready[sid]=false;
                        if peer.subscriptions[sid] {peer.checkpoint(&sessions[sid],sid,limit)?;}
                        return Ok(json!({"subscribed":peer.subscriptions[sid]}));
                    }
                    if action=="synchronized" {
                        ensure!(request["syncToken"].as_u64()==Some(peer.sync_tokens[sid]) && !peer.needs_sync,"stale synchronization token");
                        peer.ready[sid]=peer.subscriptions[sid];return Ok(json!({"ready":peer.ready[sid]}));
                    }
                    if action=="checkpoint" {peer.checkpoint(&sessions[sid],sid,limit)?;return Ok(json!({"queued":true}));}
                    let session=&mut sessions[sid];
                    if action=="take" {
                        ensure!(request["expectedOwner"]==json!(session.owner) && request["revision"].as_u64()==Some(session.revision),"stale takeover");
                        ensure!(peer.ready[sid],"synchronize before takeover");
                        let cols=request["cols"].as_u64().unwrap_or(120) as usize;let rows=request["rows"].as_u64().unwrap_or(40) as usize;
                        // Geometry is checked before ownership changes.
                        let event=session.resize(cols,rows)?;session.owner=Some(client);session.revision+=1;
                        broadcast(&mut peers,sid,event,limit)?;
                        broadcast(&mut peers,sid,json!({"kind":"control","state":sessions[sid].state()}),limit)?;
                        return Ok(sessions[sid].state());
                    }
                    ensure!(session.owner.as_deref()==Some(client.as_str()) && request["revision"].as_u64()==Some(session.revision),"not current controller");
                    if action=="release" {
                        session.owner=None;session.revision+=1;
                        let state=session.state();
                        broadcast(&mut peers,sid,json!({"kind":"control","state":state}),limit)?;
                        return Ok(state);
                    }
                    ensure!(peer.ready[sid],"input gated during synchronization");
                    if action=="input" {
                        let bytes=B64.decode(request["data"].as_str().context("input data")?)?;ensure!(bytes.len()<=4096,"input bound");
                        session.writes.lock().map_err(|_|anyhow::anyhow!("PTY queue lock"))?.enqueue(&bytes)?;
                        session.input_count+=1;return Ok(session.state());
                    }
                    if action=="resize" {
                        let event=session.resize(request["cols"].as_u64().context("cols")? as usize,request["rows"].as_u64().context("rows")? as usize)?;
                        broadcast(&mut peers,sid,event,limit)?;return Ok(sessions[sid].state());
                    }
                    bail!("unknown command")
                })();
                let response=match result {Ok(value)=>json!({"kind":"ack","id":id,"ok":true,"result":value}),
                    Err(error)=>json!({"kind":"ack","id":id,"ok":false,"error":format!("{error:#}"),
                        "state":request["session"].as_u64().and_then(|sid|sessions.get(sid as usize)).map(Session::state)})};
                if let Err(error)=peers[index].queue(response,limit) {
                    eprintln!("viewer control queue rejected: {error:#}");peers[index].close=true;break;
                }
            }
            if peers[index].needs_sync && peers[index].queued==0 {
                peers[index].needs_sync=false;
                for sid in 0..2 {if peers[index].subscriptions[sid] {
                    if let Err(error)=peers[index].checkpoint(&sessions[sid],sid,limit) {
                        eprintln!("viewer checkpoint queue rejected: {error:#}");peers[index].close=true;break;
                    }
                }}
            }
        }
        peers.retain(|peer| {
            let keep=!peer.close && !(!peer.committed && peer.born.elapsed()>Duration::from_secs(5));
            if !keep {max_queue=max_queue.max(peer.high_water);resyncs+=peer.resyncs;wire_bytes+=peer.wire_bytes;}keep
        });
        std::thread::sleep(Duration::from_millis(1));
    }
    // Flush the stop acknowledgement without extending the experiment indefinitely.
    for _ in 0..50 {for peer in &mut peers {if let Err(error)=peer.network(){eprintln!("shutdown peer: {error:#}");}}std::thread::sleep(Duration::from_millis(1));}
    Ok(())
}
