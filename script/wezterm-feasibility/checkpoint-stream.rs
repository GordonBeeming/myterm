// Native producer for the controlled handoff test. The OS pipe provides bounded
// backpressure while the client imports; there is no replay history queue.
fn stream_run() -> Result<()> {
    let mut input = Vec::new();
    io::stdin().take(4 * 1024 * 1024 + 1).read_to_end(&mut input)?;
    anyhow::ensure!(input.len() <= 4 * 1024 * 1024, "stream fixture input limit");
    let traces: Vec<Trace> = serde_json::from_slice(&input)?;
    anyhow::ensure!(traces.len() == 1, "one stream fixture required");
    let replies = Replies::new();
    let mut term = Terminal::new(TerminalSize {cols:20, rows:6, pixel_width:180, pixel_height:96, dpi:96},
        Arc::new(Config), "MyTerm-prototype", "0", Box::new(replies.clone()));
    term.advance_bytes(b"\x1b]2;\x07");
    let mut started = false;
    let mut writer = io::stdout().lock();
    for (sequence, event) in traces[0].events.iter().enumerate() {
        if let Some(size) = &event.resize {
            anyhow::ensure!(size.len() == 2 && (2..=1000).contains(&size[0]) && (1..=1000).contains(&size[1]),
                "stream geometry limit");
            term.resize(TerminalSize {cols:size[0],rows:size[1],pixel_width:size[0]*9,pixel_height:size[1]*16,dpi:96});
        }
        if let Some(bytes) = &event.data { term.advance_bytes(bytes); }
        if started {
            serde_json::to_writer(&mut writer, &json!({"sequence":sequence,"event":{
                "data":event.data,"resize":event.resize}}))?;
            writer.write_all(b"\n")?; writer.flush()?;
        } else if event.checkpoint == Some(true) {
            let bytes = term.prototype_checkpoint(sequence)?;
            serde_json::to_writer(&mut writer, &json!({"checkpoint":bytes}))?;
            writer.write_all(b"\n")?; writer.flush()?;
            started = true;
        }
    }
    anyhow::ensure!(started, "stream has no checkpoint");
    Ok(())
}
