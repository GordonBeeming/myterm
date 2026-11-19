"""Explicit scratch-core state extensions required by the native client contract."""
from pathlib import Path


def extend(scratch, replace_once):
    state = scratch / "term/src/terminalstate/mod.rs"
    replace_once(state, "pub(crate) struct SavedCursor {\n    position:", "pub(crate) struct SavedCursor {\n    pub(crate) position:")
    replace_once(state, "    config: Arc<dyn TerminalConfiguration>,\n\n    screen: ScreenOrAlt,",
        "    config: Arc<dyn TerminalConfiguration>,\n    prototype_last_print: [Option<(usize, StableRowIndex, usize, usize)>; 2],\n    prototype_image_requests: std::collections::HashMap<([u8;32],usize,usize),serde_json::Value>,\n    prototype_image_request_overflow: bool,\n\n    screen: ScreenOrAlt,")
    replace_once(state, "            config,\n            screen,", "            config,\n            prototype_last_print: [None, None],\n            prototype_image_requests: std::collections::HashMap::new(),\n            prototype_image_request_overflow: false,\n            screen,")
    replace_once(state, "    g1_charset: CharSet,\n    // TODO: selective_erase", "    g1_charset: CharSet,\n    prototype_wrap: bool,\n    prototype_reverse_wrap: bool,\n    prototype_margin: bool,\n    // TODO: selective_erase")
    replace_once(state, "            g1_charset: self.g1_charset,", "            g1_charset: self.g1_charset,\n            prototype_wrap: self.dec_auto_wrap,\n            prototype_reverse_wrap: self.reverse_wraparound_mode,\n            prototype_margin: self.left_and_right_margin_mode,")
    replace_once(state, "                g1_charset: CharSet::Ascii,\n            });", "                g1_charset: CharSet::Ascii,\n                prototype_wrap: false,\n                prototype_reverse_wrap: false,\n                prototype_margin: false,\n            });")
    replace_once(state, "        self.g1_charset = saved.g1_charset;", "        self.g1_charset = saved.g1_charset;\n        self.dec_auto_wrap = saved.prototype_wrap;\n        self.reverse_wraparound_mode = saved.prototype_reverse_wrap;\n        self.left_and_right_margin_mode = saved.prototype_margin;")
    replace_once(state, "    fn set_hyperlink(&mut self, link: Option<Hyperlink>) {", "    fn set_hyperlink(&mut self, link: Option<Hyperlink>) {\n        if link.is_none() { self.prototype_close_link_boundary(); }")
    replace_once(state, "    fn scroll_up(&mut self, num_rows: usize) {\n        let seqno = self.seqno;\n        let blank_attr = self.pen.clone_sgr_only();", "    fn scroll_up(&mut self, num_rows: usize) {\n        let seqno = self.seqno;\n        let blank_attr = self.prototype_erase_attribute();")
    replace_once(state, "    fn scroll_down(&mut self, num_rows: usize) {\n        let seqno = self.seqno;\n        let blank_attr = self.pen.clone_sgr_only();", "    fn scroll_down(&mut self, num_rows: usize) {\n        let seqno = self.seqno;\n        let blank_attr = self.prototype_erase_attribute();")
    text = state.read_text()
    text = text.replace("self.screen.activate_alt_screen(self.seqno)", "self.prototype_switch_buffer(true)")
    text = text.replace("self.screen.activate_primary_screen(self.seqno)", "self.prototype_switch_buffer(false)")
    state.write_text(text)
    screen = scratch / "term/src/screen.rs"
    replace_once(screen, "    pub(crate) saved_cursor: Option<SavedCursor>,", "    pub(crate) saved_cursor: Option<SavedCursor>,\n    pub(crate) prototype_margins: [usize;4],\n    pub(crate) prototype_unsaved_y: usize,")
    replace_once(screen, "            saved_cursor: None,", "            saved_cursor: None,\n            prototype_margins: [0,size.rows,0,size.cols],\n            prototype_unsaved_y: 0,")
    replace_once(screen, "            keyboard_stack: vec![],", "            keyboard_stack: vec![KeyboardEncoding::Xterm],")
    replace_once(screen, "        self.keyboard_stack.clear();", "        self.keyboard_stack = vec![KeyboardEncoding::Xterm];")
    replace_once(screen, "    ) -> CursorPosition {\n        let physical_rows = size.rows.max(1);", "    ) -> CursorPosition {\n        let old_history = self.lines.len().saturating_sub(self.physical_rows);\n        let old_rows = self.physical_rows;\n        let physical_rows = size.rows.max(1);\n        let pulled = physical_rows.saturating_sub(old_rows).min(old_history);\n        self.prototype_unsaved_y = (self.prototype_unsaved_y + pulled).min(physical_rows - 1);\n        if let Some(saved) = self.saved_cursor.as_mut() { saved.position.y = (saved.position.y + pulled as i64).min(physical_rows as i64 - 1); saved.position.x = saved.position.x.min(size.cols.max(1) - 1); }\n        self.prototype_margins = [0,physical_rows,0,size.cols];")
    replace_once(screen, "        self.physical_rows = physical_rows;", """        // Shrinking a full viewport must retain only the configured history.
        let removed = self.lines.len().saturating_sub(capacity);
        for _ in 0..removed { self.lines.pop_front(); }
        self.stable_row_index_offset += removed;
        self.physical_rows = physical_rows;""")
    replace_once(screen, "        let cursor_phys = self.phys_row(cursor.y);", "        let cursor_phys = self.phys_row(cursor.y);\n        let clamp_blank_cursor = size.rows == self.physical_rows && self.allow_scrollback && self.lines.get(cursor_phys).map(Line::is_whitespace).unwrap_or(false);")
    replace_once(screen, "            x: cursor_x.min(physical_cols - 1),\n            y: new_cursor_y,", "            x: if clamp_blank_cursor { cursor.x.min(physical_cols - 1) } else { cursor_x.min(physical_cols - 1) },\n            y: if clamp_blank_cursor { cursor.y } else { new_cursor_y },")
    apc = scratch / "wezterm-escape-parser/src/apc.rs"
    replace_once(apc, 'keys.insert("a", "Q".to_string());', 'keys.insert("a", "T".to_string());')
    performer = scratch / "term/src/terminalstate/performer.rs"
    replace_once(performer, "            Esc::Code(EscCode::FullReset) => {", """            Esc::Code(EscCode::FullReset) => {
                self.kitty_img = Default::default();
                self.prototype_image_requests.clear();
                self.prototype_image_request_overflow = false;
                self.prototype_last_print = [None, None];""")
    replace_once(performer, "                    self.screen_mut().keyboard_stack.pop();\n                }\n            }\n            CSI::Keyboard(Keyboard::QueryKittySupport)", "                    let stack = &mut self.screen_mut().keyboard_stack;\n                    if stack.len()>1 { stack.pop(); } else { *stack = vec![KeyboardEncoding::Xterm]; }\n                }\n            }\n            CSI::Keyboard(Keyboard::QueryKittySupport)")
    replace_once(performer, "            let g = self.remap_grapheme(g);", "            let g = self.remap_grapheme(g);\n            if self.state.prototype_combine(g) { continue; }")
    replace_once(performer, "                .set_cell_grapheme(x, y, g, print_width, pen, seqno);", "                .set_cell_grapheme(x, y, g, print_width, pen, seqno);\n            self.state.prototype_record_print(x, y);")
    sixel = scratch / "term/src/terminalstate/sixel.rs"
    old = sixel.read_text()
    begin = old.index("                    let angle = (*hue_angle as f64) - 120.0;")
    end = old.index("                    color_map.insert(*color_number, RgbColor::new_8bpc(r, g, b));",begin)
    end += len("                    color_map.insert(*color_number, RgbColor::new_8bpc(r, g, b));")
    sixel.write_text(old[:begin]+"                    color_map.insert(*color_number, Self::prototype_sixel_hls(*hue_angle as usize,*lightness as usize,*saturation as usize));"+old[end:])
    iterm = scratch / "term/src/terminalstate/iterm.rs"
    replace_once(iterm, "    pub(crate) fn set_image(&mut self, image: ITermFileData) {", "    pub(crate) fn set_image(&mut self, image: ITermFileData) {\n        let prototype_request = serde_json::json!({\"width\":format!(\"{}\",image.width),\"height\":format!(\"{}\",image.height),\"preserve\":image.preserve_aspect_ratio});")
    replace_once(iterm, "        if let Err(err) = self.assign_image_to_cells(ImageAttachParams {", "        self.prototype_store_image_request(image_data.hash(),width,height,prototype_request);\n        if let Err(err) = self.assign_image_to_cells(ImageAttachParams {")
    kitty = scratch / "term/src/terminalstate/kitty.rs"
    replace_once(kitty, "    placements: HashMap<(u32, Option<u32>), PlacementInfo>,", "    placements: HashMap<(u32, Option<u32>), PlacementInfo>,\n    prototype_placement_buffers: HashMap<(u32, Option<u32>), bool>,")
    replace_once(kitty, "            .insert((image_id, placement.placement_id), info);", "            .insert((image_id, placement.placement_id), info);\n        self.kitty_img.prototype_placement_buffers.insert((image_id, placement.placement_id), self.screen.alt_screen_is_active);\n        let placements = &self.kitty_img.placements;\n        self.kitty_img.prototype_placement_buffers.retain(|key,_| placements.contains_key(key));")
    replace_once(kitty, "        let info = self.assign_image_to_cells(ImageAttachParams {", "        let prototype_request = serde_json::json!({\"width\":placement.columns.map(|n|n.to_string()).unwrap_or_else(||\"auto\".into()),\"height\":placement.rows.map(|n|n.to_string()).unwrap_or_else(||\"auto\".into()),\"preserve\":placement.columns.is_none() || placement.rows.is_none()});\n        let target_width = placement.columns.map(|n|n as usize*(self.pixel_width/self.screen().physical_cols)).unwrap_or(image_width as usize);\n        let target_height = placement.rows.map(|n|n as usize*(self.pixel_height/self.screen().physical_rows)).unwrap_or(image_height as usize);\n        self.prototype_store_image_request(img.hash(),target_width,target_height,prototype_request);\n        let info = self.assign_image_to_cells(ImageAttachParams {")


def extend_swift(swift, replace_once):
    # Full-width margins follow a widening viewport; explicit narrower margins
    # retain their requested positions. This change remains in the scratch copy.
    replace_once(swift / "Sources/SwiftTerm/Buffer.swift", "        if marginRight > newCols - 1 {", "        if marginRight == cols - 1 && marginLeft == 0 { marginRight = newCols - 1 }\n        if marginRight > newCols - 1 {")

    replace_once(swift / "Sources/SwiftTerm/Terminal.swift", "        normalBuffer.savedY = normalBuffer.y + dy", "        normalBuffer.savedY = min(max(0, normalBuffer.y + dy), newRows - 1)")
