// Included inside the scratch engine's terminalstate module, never production.
use serde_json::{json, Value as BridgeValue};
include!("prototype-graphics.rs");

fn bridge_color(c: crate::color::ColorAttribute) -> BridgeValue {
    use crate::color::ColorAttribute::*;
    match c {
        Default => json!([2, 0, 0, 0]),
        PaletteIndex(i) => json!([0, i, 0, 0]),
        TrueColorWithPaletteFallback(c, _) | TrueColorWithDefaultFallback(c) => {
            let (r, g, b, _) = c.to_srgb_u8(); json!([1, r, g, b])
        }
    }
}

fn bridge_attribute(a: &CellAttributes) -> anyhow::Result<BridgeValue> {
    use crate::{Intensity, Underline};
    let underline = match a.underline() {
        Underline::None => 0, Underline::Single => 1,
        _ => anyhow::bail!("unsupported underline variant"),
    };
    let style: u8 = if a.intensity() == Intensity::Bold {1} else {0}
        | if underline != 0 {2} else {0}
        | if a.blink() != crate::Blink::None {4} else {0}
        | if a.reverse() {8} else {0}
        | if a.invisible() {16} else {0}
        | if a.intensity() == Intensity::Half {32} else {0}
        | if a.italic() {64} else {0}
        | if a.strikethrough() {128} else {0};
    anyhow::ensure!(a.hyperlink().map_or(true, |h| h.params().is_empty()), "unsupported hyperlink parameters");
    Ok(json!({"fg": bridge_color(a.foreground()), "bg": bridge_color(a.background()),
        "style":style,"underline":underline,
        "underlineColor":bridge_color(a.underline_color()),
        "link":a.hyperlink().map(|h|format!(";{}", h.uri()))}))
}

fn bridge_saved(saved: &Option<SavedCursor>) -> anyhow::Result<BridgeValue> {
    match saved {
        None => Ok(BridgeValue::Null),
        Some(s) => {
            anyhow::ensure!(s.g0_charset == CharSet::Ascii && s.g1_charset == CharSet::Ascii,
                "unsupported saved charset");
            Ok(json!({"x":s.position.x,"y":s.position.y,"wrapNext":s.wrap_next,
                "origin":s.dec_origin_mode,"pen":bridge_attribute(&s.pen)?,
                "wrap":s.prototype_wrap,"reverseWrap":s.prototype_reverse_wrap,"margin":s.prototype_margin}))
        }
    }
}

fn bridge_keyboard(screen: &Screen) -> anyhow::Result<BridgeValue> {
    anyhow::ensure!(screen.keyboard_stack.len() <= 128, "keyboard stack limit");
    let flags: Vec<u16> = screen.keyboard_stack.iter().map(|encoding| match encoding {
        KeyboardEncoding::Xterm => Ok(0), KeyboardEncoding::Kitty(flags) => Ok(flags.bits()),
        _ => Err(anyhow::anyhow!("unsupported keyboard encoding")),
    }).collect::<anyhow::Result<_>>()?;
    Ok(json!({"flags":flags.last().copied().unwrap_or(0), "stack":if flags.is_empty() {&flags[..]} else {&flags[..flags.len()-1]}}))
}

fn bridge_screen(screen: &Screen, normal: bool, margins: [usize;4], budget: &mut usize, allocated: &mut usize,
    graphics: &mut BridgeGraphics, cell_width: usize, cell_height: usize,
    requests: &std::collections::HashMap<([u8;32],usize,usize),BridgeValue>) -> anyhow::Result<BridgeValue> {
    let count = screen.scrollback_rows();
    anyhow::ensure!(count <= screen.physical_rows + if normal {40} else {0}, "checkpoint line limit");
    let lines = screen.lines_in_phys_range(0..count);
    let mut output = Vec::new();
    for line in lines {
        anyhow::ensure!(!line.is_double_width() && !line.is_double_height_top()
            && !line.is_double_height_bottom(), "unsupported line render mode");
        let width = line.len().max(screen.physical_cols);
        anyhow::ensure!(width <= 1000 && (!normal || width == screen.physical_cols), "checkpoint stored column limit");
        *allocated = allocated.checked_add(width).ok_or_else(||anyhow::anyhow!("cell count overflow"))?;
        anyhow::ensure!(*allocated <= 100_000, "checkpoint allocated cell limit");
        let mut cells = Vec::new();
        for cell in line.visible_cells() {
            let cost = cell.str().len();
            *budget = budget.checked_add(cost).ok_or_else(||anyhow::anyhow!("cell budget overflow"))?;
            anyhow::ensure!(*budget <= 1_048_576, "checkpoint text budget");
            let attribute = bridge_attribute(cell.attrs())?;
            if cell.width() == 1 {
                if let Some(last) = cells.last_mut() {
                    let last: &mut BridgeValue = last;
                    if last["width"] == 1 && last["text"] == cell.str() && last["attribute"] == attribute
                        && last["x"].as_u64().unwrap_or(u64::MAX)
                            .checked_add(last["repetitions"].as_u64().unwrap_or(0)) == Some(cell.cell_index() as u64) {
                        let count = last["repetitions"].as_u64().ok_or_else(||anyhow::anyhow!("run length missing"))?;
                        last["repetitions"] = json!(count + 1);
                        continue;
                    }
                }
            }
            cells.push(json!({"x":cell.cell_index(),"text":cell.str(),"width":cell.width(),
                "repetitions":1,"attribute":attribute}));
        }
        output.push(json!({"wrapped":line.last_cell_was_wrapped(),"cells":cells,
            "width":line.len().max(screen.physical_cols),"images":graphics.row(&line,cell_width,cell_height,requests)?}));
    }
    Ok(json!({"lines":output,"saved":bridge_saved(&screen.saved_cursor)?,"margins":margins,
        "defaultSavedY":screen.prototype_unsaved_y}))
}

impl TerminalState {
    pub(crate) fn prototype_store_image_request(&mut self, hash: [u8;32], width: usize, height: usize, request: BridgeValue) {
        let mut referenced: std::collections::HashSet<[u8;32]> = self.image_cache.iter().map(|(key,_)|*key).collect();
        for screen in [&self.screen.screen,&self.screen.alt_screen] {
            for line in screen.lines_in_phys_range(0..screen.scrollback_rows()) {
                for cell in line.visible_cells() { for image in cell.attrs().images().unwrap_or_default() {
                    referenced.insert(image.image_data().hash());
                }}
            }
        }
        self.prototype_image_requests.retain(|key,_|referenced.contains(&key.0));
        if self.prototype_image_requests.len()>=64 && !self.prototype_image_requests.contains_key(&(hash,width,height)) {
            self.prototype_image_request_overflow = true;
        } else { self.prototype_image_requests.insert((hash,width,height),request); }
    }
    pub(crate) fn prototype_sixel_hls(hue: usize, lightness: usize, saturation: usize) -> RgbColor {
        let l = lightness.min(100) as f64;
        let s = saturation.min(100) as f64;
        let delta = s*(1.0-(2.0*l/100.0-1.0).abs())/2.0;
        let lo = l-delta; let hi = l+delta;
        let h = ((hue.min(360)+240)%360) as f64;
        let (r,g,b) = match h as usize/60 {
            0 => (hi,lo+(hi-lo)*h/60.0,lo), 1 => (lo+(hi-lo)*(120.0-h)/60.0,hi,lo),
            2 => (lo,hi,lo+(hi-lo)*(h-120.0)/60.0), 3 => (lo,lo+(hi-lo)*(240.0-h)/60.0,hi),
            4 => (lo+(hi-lo)*(h-240.0)/60.0,lo,hi), _ => (hi,lo,lo+(hi-lo)*(360.0-h)/60.0),
        };
        let byte = |v:f64| ((v.clamp(0.0,100.0) as usize)*255/100) as u8;
        RgbColor::new_8bpc(byte(r),byte(g),byte(b))
    }

    pub(crate) fn prototype_erase_attribute(&self) -> CellAttributes {
        let mut result = CellAttributes::default();
        result.set_background(self.pen.background());
        result
    }

    pub(crate) fn prototype_close_link_boundary(&mut self) {
        let Some(link) = self.pen.hyperlink().cloned() else { return; };
        // SwiftTerm retains the closing cursor cell as part of a closed link.
        // Preserve that existing client behavior instead of dropping its payload.
        let x = self.cursor.x.min(self.screen().physical_cols - 1);
        let y = self.cursor.y;
        let physical = self.screen().phys_row(y);
        let previous = if x > 0 {
            self.screen().lines_in_phys_range(physical..physical+1).first().map(|line|
                line.visible_cells().any(|c| c.cell_index()+c.width()==x && c.attrs().hyperlink()==Some(&link))).unwrap_or(false)
        } else { false };
        if !previous { return; }
        let mut cell = self.screen_mut().get_cell(x,y).cloned().unwrap_or_else(Cell::blank);
        cell.attrs_mut().set_hyperlink(Some(link));
        let seqno = self.seqno;
        self.screen_mut().set_cell(x,y,&cell,seqno);
    }

    pub(crate) fn prototype_switch_buffer(&mut self, alternate: bool) {
        if !alternate && self.screen.alt_screen_is_active { self.prototype_clear_alt_kitty(); }
        let margins = [self.top_and_bottom_margins.start as usize,self.top_and_bottom_margins.end as usize,
            self.left_and_right_margins.start,self.left_and_right_margins.end];
        if self.screen.alt_screen_is_active {self.screen.alt_screen.prototype_margins = margins;}
        else {self.screen.screen.prototype_margins = margins;}
        if alternate {self.screen.activate_alt_screen(self.seqno);} else {self.screen.activate_primary_screen(self.seqno);}
        let margins = if alternate {self.screen.alt_screen.prototype_margins} else {self.screen.screen.prototype_margins};
        self.top_and_bottom_margins = margins[0] as i64..margins[1] as i64;
        self.left_and_right_margins = margins[2]..margins[3];
    }
    pub(crate) fn prototype_record_print(&mut self, x: usize, y: VisibleRowIndex) {
        let screen = self.screen();
        let stable = screen.phys_to_stable_row_index(screen.phys_row(y));
        self.prototype_last_print[usize::from(self.screen.alt_screen_is_active)] =
            Some((x, stable, screen.physical_cols, screen.physical_rows));
    }

    pub(crate) fn prototype_combine(&mut self, text: &str) -> bool {
        if text.is_ascii() { return false; }
        let Some((x, stable, cols, rows)) = self.prototype_last_print[usize::from(self.screen.alt_screen_is_active)] else { return false; };
        let screen = self.screen();
        if cols != screen.physical_cols || rows != screen.physical_rows { return false; }
        let Some(physical) = screen.stable_row_to_phys(stable) else { return false; };
        let lines = screen.lines_in_phys_range(physical..physical+1);
        let Some(line) = lines.first() else { return false; };
        let Some(cell) = line.visible_cells().find(|c|c.cell_index() == x) else { return false; };
        let joined = format!("{}{}", cell.str(), text);
        if finl_unicode::grapheme_clusters::Graphemes::new(&joined).count() != 1 { return false; }
        let width = cell.width();
        let attrs = cell.attrs().clone();
        let y = physical as i64 - self.screen().phys_row(0) as i64;
        let seqno = self.seqno;
        self.screen_mut().set_cell_grapheme(x, y, &joined, width, attrs, seqno);
        true
    }

    fn prototype_last_storage(&self, alternate: bool) -> BridgeValue {
        let screen = if alternate {&self.screen.alt_screen} else {&self.screen.screen};
        match self.prototype_last_print[usize::from(alternate)] {
            Some((x, stable, cols, rows)) => match screen.stable_row_to_phys(stable) {
                Some(y) => json!([x,y,cols,rows]), None => BridgeValue::Null },
            None => BridgeValue::Null
        }
    }

    pub fn prototype_checkpoint_state(&self) -> anyhow::Result<BridgeValue> {
        anyhow::ensure!((2..=1000).contains(&self.screen.physical_cols)
            && (1..=1000).contains(&self.screen.physical_rows), "checkpoint dimension limit");
        anyhow::ensure!(self.palette.is_none(), "unsupported dynamic palette");
        anyhow::ensure!(self.g0_charset == CharSet::Ascii && self.g1_charset == CharSet::Ascii
            && !self.shift_out, "unsupported charset");
        anyhow::ensure!(self.keyboard_encoding == KeyboardEncoding::Xterm, "unsupported keyboard encoding");
        let kitty = self.kitty_img.prototype_checkpoint()?;
        anyhow::ensure!(!self.reverse_video_mode && !self.enable_conpty_quirks
            && self.modify_other_keys.is_none() && !self.dec_ansi_mode
            && self.unicode_version_stack.is_empty() && self.bidi_enabled.is_none()
            && self.bidi_hint.is_none(), "unsupported extended terminal state");
        anyhow::ensure!(self.pen.hyperlink().is_none(), "unsupported open hyperlink");
        let mut budget = 0;
        let mut allocated = 0;
        let mut graphics = BridgeGraphics::default();
        let active_margins = [self.top_and_bottom_margins.start as usize,self.top_and_bottom_margins.end as usize,
            self.left_and_right_margins.start,self.left_and_right_margins.end];
        let cell_width = self.pixel_width/self.screen.physical_cols;
        let cell_height = self.pixel_height/self.screen.physical_rows;
        let normal = bridge_screen(&self.screen.screen, true, if !self.screen.alt_screen_is_active {active_margins} else {self.screen.screen.prototype_margins}, &mut budget, &mut allocated, &mut graphics,cell_width,cell_height,&self.prototype_image_requests)?;
        let alternate = bridge_screen(&self.screen.alt_screen, false, if self.screen.alt_screen_is_active {active_margins} else {self.screen.alt_screen.prototype_margins}, &mut budget, &mut allocated, &mut graphics,cell_width,cell_height,&self.prototype_image_requests)?;
        Ok(json!({"columns":self.screen.physical_cols,"rows":self.screen.physical_rows,
            "normal":normal,"alternate":alternate,"graphics":graphics.resources.into_values().collect::<Vec<_>>(),
            "cellPixels":[cell_width,cell_height],
            "kitty":kitty,
            "alternateActive":self.screen.alt_screen_is_active,
            "lastStorage":[self.prototype_last_storage(false),self.prototype_last_storage(true)],
            "keyboard":[bridge_keyboard(&self.screen.screen)?,bridge_keyboard(&self.screen.alt_screen)?],
            "cursor":[self.cursor.x,self.cursor.y],"wrapNext":self.wrap_next,
            "cursorStyle":match self.cursor.shape { CursorShape::Default|CursorShape::BlinkingBlock=>0,
                CursorShape::SteadyBlock=>1,CursorShape::BlinkingUnderline=>2,CursorShape::SteadyUnderline=>3,
                CursorShape::BlinkingBar=>4,CursorShape::SteadyBar=>5 },
            "pen":bridge_attribute(&self.pen)?,"title":self.title,"iconTitle":self.icon_title,
            "tabs":self.tabs.tabs,"tabWidth":self.tabs.tab_width,
            "margins":[self.top_and_bottom_margins.start,self.top_and_bottom_margins.end,
                self.left_and_right_margins.start,self.left_and_right_margins.end],
            "modes":{"applicationCursor":self.application_cursor_keys,"applicationKeypad":self.application_keypad,
                "origin":self.dec_origin_mode,"margin":self.left_and_right_margin_mode,"insert":self.insert,
                "wrap":self.dec_auto_wrap,"reverseWrap":self.reverse_wraparound_mode,
                "paste":self.bracketed_paste,"focus":self.focus_tracking,"cursorHidden":!self.cursor_visible,
                "newline":self.newline_mode,"mouse":if self.any_event_mouse {4} else if self.button_event_mouse {3}
                    else if self.mouse_tracking {2} else {0},
                "mouseProtocol":match self.mouse_encoding {MouseEncoding::X10=>0,MouseEncoding::Utf8=>1,
                    MouseEncoding::SGR=>2,MouseEncoding::SgrPixels=>4}},
            "directory":self.current_dir.as_ref().map(|u|u.as_str())}))
    }
}
