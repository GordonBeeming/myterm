// Throwaway probe, not a MyTerm server or synchronization protocol.
use anyhow::{bail, Context, Result};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    io::{self, BufRead, BufReader, Read, Write},
    net::TcpListener,
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

#[derive(Deserialize)]
struct Event {
    #[serde(default)]
    data: Vec<u8>,
    #[serde(default)]
    resize: Vec<u16>,
    #[serde(default)]
    checkpoint: bool,
}
#[derive(Deserialize)]
struct Trace {
    name: String,
    events: Vec<Event>,
}
fn color_code(c: vt100::Color) -> String {
    match c {
        vt100::Color::Default => "default".into(),
        vt100::Color::Idx(i) => format!("idx:{i}"),
        vt100::Color::Rgb(r, g, b) => format!("rgb:{r},{g},{b}"),
    }
}
fn snapshot(parser: &vt100::Parser) -> Value {
    let screen = parser.screen();
    let (rows, cols) = screen.size();
    let cells: Vec<Vec<String>> = (0..rows.get())
        .map(|y| {
            (0..cols.get())
                .map(|x| {
                    screen
                        .cell(y, x)
                        .map(|c| {
                            let s = c.contents();
                            if s == " " {
                                String::new()
                            } else {
                                s.to_string()
                            }
                        })
                        .unwrap_or_default()
                })
                .collect()
        })
        .collect();
    let styles: Vec<Vec<String>> = (0..rows.get())
        .map(|y| {
            (0..cols.get())
                .map(|x| {
                    screen
                        .cell(y, x)
                        .map(|c| {
                            format!(
                                "{}|{}|{}{}{}{}",
                                color_code(c.fgcolor()),
                                color_code(c.bgcolor()),
                                c.bold(),
                                c.italic(),
                                c.underline(),
                                c.inverse()
                            )
                        })
                        .unwrap_or_default()
                })
                .collect()
        })
        .collect();
    let (y, x) = screen.cursor_position();
    json!({"cells": cells, "styles":styles, "cursor": [x,y], "alt": screen.alternate_screen(), "replies": [], "history": null})
}
fn traces() -> Result<()> {
    let input: Vec<Trace> = serde_json::from_reader(io::stdin())?;
    let mut output = serde_json::Map::new();
    for trace in input {
        let mut parser = vt100::Parser::new(
            std::num::NonZeroU16::new(6).context("rows")?,
            std::num::NonZeroU16::new(20).context("columns")?,
            40,
        );
        let mut snaps = vec![];
        let mut renders = vec![];
        let mut restored: Option<vt100::Parser> = None;
        let mut checkpoint_checks = vec![];
        let mut reconstruction_snapshots = vec![];
        for event in trace.events {
            if event.resize.len() == 2 {
                parser.set_size(
                    std::num::NonZeroU16::new(event.resize[1]).context("rows")?,
                    std::num::NonZeroU16::new(event.resize[0]).context("columns")?,
                );
                if let Some(p) = restored.as_mut() {
                    p.set_size(
                        std::num::NonZeroU16::new(event.resize[1]).context("rows")?,
                        std::num::NonZeroU16::new(event.resize[0]).context("columns")?,
                    );
                }
            }
            parser.process(&event.data);
            if let Some(p) = restored.as_mut() {
                p.process(&event.data);
            }
            snaps.push(snapshot(&parser));
            if let Some(p) = restored.as_ref() {
                checkpoint_checks.push(snapshot(p) == snapshot(&parser));
            }
            if event.checkpoint {
                let render = parser.screen().state_formatted();
                let (rows, cols) = parser.screen().size();
                let mut fresh = vt100::Parser::new(rows, cols, 40);
                fresh.process(render.as_bytes());
                checkpoint_checks.push(snapshot(&fresh) == snapshot(&parser));
                renders.push(render);
                restored = Some(fresh);
            }
            reconstruction_snapshots.push(restored.as_ref().map(snapshot));
        }
        output.insert(trace.name,json!({"snapshots":snaps,"finalReplies":[],"screenRenders":renders,"checkpointChecks":checkpoint_checks,"reconstructionSnapshots":reconstruction_snapshots,"replyImplementation":false,"checkpoint":"state_formatted restores displayed state; parser, inactive buffer and image continuity require separate checks","images":"No image retention API exercised"}));
    }
    serde_json::to_writer(io::stdout(), &output)?;
    println!();
    Ok(())
}
#[derive(Deserialize)]
struct Request {
    token: String,
    op: String,
    #[serde(default)]
    data: Vec<u8>,
    #[serde(default)]
    cols: u16,
    #[serde(default)]
    rows: u16,
}
struct ChildGuard(Box<dyn portable_pty::Child + Send + Sync>);
impl Drop for ChildGuard {
    fn drop(&mut self) {
        match self.0.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) => {}
            Err(e) => eprintln!("cleanup status: {e}"),
        }
        if let Err(e) = self.0.kill() {
            eprintln!("cleanup kill: {e}");
        }
        if let Err(e) = self.0.wait() {
            eprintln!("cleanup wait: {e}");
        }
    }
}
// portable-pty requests the inherited cursor even for this fresh headless terminal.
// Answer only its one startup request; application-query policy remains unimplemented.
#[cfg(any(windows, test))]
#[derive(Default)]
struct StartupCursorQuery {
    matched: usize,
    answered: bool,
}
#[cfg(any(windows, test))]
impl StartupCursorQuery {
    fn observe(&mut self, bytes: &[u8]) -> bool {
        const QUERY: &[u8] = b"\x1b[6n";
        if self.answered {
            return false;
        }
        for byte in bytes {
            if *byte == QUERY[self.matched] {
                self.matched += 1;
            } else {
                self.matched = usize::from(*byte == QUERY[0]);
            }
            if self.matched == QUERY.len() {
                self.answered = true;
                return true;
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::StartupCursorQuery;
    #[test]
    fn blocked_input_cannot_block_the_session_loop() {
        use std::{
            io::{self, Write},
            sync::{mpsc, Arc, Mutex},
            time::Duration,
        };
        struct BlockedInput {
            release: mpsc::Receiver<()>,
            finished: mpsc::Sender<()>,
        }
        impl Write for BlockedInput {
            fn write(&mut self, _: &[u8]) -> io::Result<usize> {
                self.release.recv().map_err(io::Error::other)?;
                self.finished.send(()).map_err(io::Error::other)?;
                Err(io::Error::other("released after timeout"))
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let (release, blocked) = mpsc::channel();
        let (finished, completion) = mpsc::channel();
        let input: super::PtyInput = Arc::new(Mutex::new(Box::new(BlockedInput {
            release: blocked,
            finished,
        })));
        assert!(matches!(
            super::write_with_timeout(input, vec![1], Duration::from_millis(20)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        release.send(()).expect("release blocked writer");
        completion
            .recv_timeout(Duration::from_secs(1))
            .expect("writer exits after release");
    }
    #[test]
    fn startup_cursor_response_handles_every_fragment_boundary_and_only_answers_once() {
        let query = b"\x1b[6n";
        for split in 0..=query.len() {
            let mut handler = StartupCursorQuery::default();
            let first = handler.observe(&query[..split]);
            let second = handler.observe(&query[split..]);
            assert_ne!(first, second);
            assert!(!handler.observe(query));
        }
        let mut handler = StartupCursorQuery::default();
        for byte in query {
            let answered = handler.observe(&[*byte]);
            assert_eq!(answered, *byte == b'n');
        }
        let mut handler = StartupCursorQuery::default();
        assert!(!handler.observe(b"\x1b[5n\x1b[?6n"));
        assert!(handler.observe(query));
    }
}

type PtyInput = Arc<Mutex<Box<dyn Write + Send>>>;
fn write_with_timeout(
    input: PtyInput,
    data: Vec<u8>,
    timeout: Duration,
) -> std::result::Result<Result<()>, std::sync::mpsc::RecvTimeoutError> {
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    thread::spawn(move || {
        let result = (|| -> Result<()> {
            let mut writer = input
                .lock()
                .map_err(|_| anyhow::anyhow!("input mutex poisoned"))?;
            writer.write_all(&data)?;
            writer.flush()?;
            Ok(())
        })();
        if let Err(undelivered) = sender.send(result) {
            eprintln!("late PTY write result after deadline: {:?}", undelivered.0);
        }
    });
    receiver.recv_timeout(timeout)
}

fn session(args: &[String]) -> Result<()> {
    let token = std::env::var("MYTERM_PROBE_TOKEN")?;
    if token.len() < 32 {
        bail!("probe token missing");
    }
    let pair = native_pty_system().openpty(PtySize {
        rows: 24,
        cols: 80,
        pixel_width: 0,
        pixel_height: 0,
    })?;
    let mut command = CommandBuilder::new(&args[0]);
    command.args(&args[1..]);
    command.env("TERM", "xterm-256color");
    let mut child = ChildGuard(pair.slave.spawn_command(command)?);
    drop(pair.slave);
    let pid = child.0.process_id().context("missing child PID")?;
    let mut reader = pair.master.try_clone_reader()?;
    let writer = Arc::new(Mutex::new(pair.master.take_writer()?));
    #[cfg(windows)]
    let startup_writer = writer.clone();
    let output = Arc::new(Mutex::new((Vec::<u8>::new(), String::new(), 0usize)));
    let captured = output.clone();
    thread::spawn(move || {
        let mut buffer = [0u8; 8192];
        #[cfg(windows)]
        let mut startup_query = StartupCursorQuery::default();
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => {
                    let mut out = captured.lock().expect("reader mutex poisoned");
                    if out.0.len() + n > 1024 * 1024 {
                        out.1 = "output bound exceeded".into();
                        break;
                    }
                    out.0.extend_from_slice(&buffer[..n]);
                    drop(out);
                    #[cfg(windows)]
                    if startup_query.observe(&buffer[..n]) {
                        let result = (|| -> Result<()> {
                            let mut input = startup_writer
                                .lock()
                                .map_err(|_| anyhow::anyhow!("input mutex poisoned"))?;
                            input.write_all(b"\x1b[1;1R")?;
                            input.flush()?;
                            Ok(())
                        })();
                        let mut out = captured.lock().expect("reader mutex poisoned");
                        if let Err(error) = result {
                            out.1 = format!("startup cursor response: {error}");
                            break;
                        }
                        out.2 += 1;
                    }
                }
                Err(e) => {
                    captured.lock().expect("reader mutex poisoned").1 = e.to_string();
                    break;
                }
            }
        }
    });
    let listener = TcpListener::bind("127.0.0.1:0")?;
    println!(
        "{}",
        json!({"address":listener.local_addr()?.to_string(),"pid":pid})
    );
    io::stdout().flush()?;
    listener.set_nonblocking(true)?;
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut observer_errors = 0usize;
    let mut last_observer_error = String::new();
    loop {
        if Instant::now() > deadline {
            bail!("session watchdog expired");
        }
        let (mut stream, _) = match listener.accept() {
            Ok(pair) => pair,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10));
                continue;
            }
            Err(e) => return Err(e.into()),
        };
        // Windows inherits nonblocking mode from the listening socket.
        stream.set_nonblocking(false)?;
        let output_length_at_accept = output
            .lock()
            .map_err(|_| anyhow::anyhow!("output mutex poisoned"))?
            .0
            .len();
        stream.set_read_timeout(Some(Duration::from_secs(5)))?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        let request = (|| -> Result<Request> {
            let mut line = String::new();
            BufReader::new((&stream).take(65536)).read_line(&mut line)?;
            Ok(serde_json::from_str(&line)?)
        })();
        let request = match request {
            Ok(r) => r,
            Err(error) => {
                observer_errors += 1;
                last_observer_error = error.to_string();
                continue;
            }
        };
        if request.token != token {
            observer_errors += 1;
            last_observer_error = "invalid token".into();
            let sent = (|| -> Result<()> {
                serde_json::to_writer(&mut stream, &json!({"error":"invalid token"}))?;
                stream.write_all(b"\n")?;
                Ok(())
            })();
            if let Err(error) = sent {
                observer_errors += 1;
                last_observer_error = error.to_string();
            }
            continue;
        }
        let stopping = request.op == "stop" || request.op == "terminate";
        let result: Result<()> = (|| {
            match request.op.as_str() {
                "write" => {
                    match write_with_timeout(writer.clone(), request.data, Duration::from_secs(5)) {
                        Ok(result) => result?,
                        Err(error) => {
                            child.0.kill()?;
                            bail!("PTY write wait failed; child terminated: {error}");
                        }
                    }
                }
                "resize" => {
                    if request.cols == 0
                        || request.rows == 0
                        || request.cols > 500
                        || request.rows > 200
                    {
                        bail!("invalid geometry");
                    }
                    pair.master.resize(PtySize {
                        rows: request.rows,
                        cols: request.cols,
                        pixel_width: 0,
                        pixel_height: 0,
                    })?;
                }
                "read" => {}
                "terminate" => {
                    child.0.kill()?;
                    child.0.wait()?;
                }
                "stop" => {
                    let deadline = Instant::now() + Duration::from_secs(5);
                    loop {
                        if let Some(status) = child.0.try_wait()? {
                            if !status.success() {
                                bail!("child exit {status}");
                            }
                            break;
                        }
                        if Instant::now() > deadline {
                            bail!("child exit timeout");
                        }
                        thread::sleep(Duration::from_millis(10));
                    }
                }
                _ => bail!("unknown operation"),
            };
            Ok(())
        })();
        let out = output
            .lock()
            .map_err(|_| anyhow::anyhow!("output mutex poisoned"))?;
        let sent = (|| -> Result<()> {
            serde_json::to_writer(
                &mut stream,
                &json!({"data":out.0,"pid":pid,"readerStatus":out.1,"startupCursorReplies":out.2,"outputLengthAtAccept":output_length_at_accept,"observerErrors":observer_errors,"lastObserverError":last_observer_error,"error":result.as_ref().err().map(ToString::to_string).unwrap_or_default()}),
            )?;
            stream.write_all(b"\n")?;
            Ok(())
        })();
        if let Err(error) = sent {
            observer_errors += 1;
            last_observer_error = error.to_string();
        }
        if stopping {
            result?;
            break;
        }
    }
    Ok(())
}
fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() > 2 && args[1] == "--session" {
        session(&args[2..])
    } else if args.len() == 1 {
        traces()
    } else {
        bail!("usage: probe [--session shell args...]")
    }
}
