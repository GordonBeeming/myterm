// Only in-progress direct transfers are rebuilt from bounded semantic records.
impl KittyImageState {
    pub(super) fn prototype_checkpoint(&self) -> anyhow::Result<serde_json::Value> {
        anyhow::ensure!(self.id_to_data.len()<=32 && self.number_to_id.len()<=32, "Kitty cache count limit");
        let mut images = Vec::new();
        let mut total = 0;
        for (id,image) in &self.id_to_data {
            let data = image.data();
            match &*data {
                ImageDataType::Rgba8{data,width,height,..} => {
                    total += data.len();
                    anyhow::ensure!(total<=262144, "Kitty cache byte limit");
                    images.push(serde_json::json!({"id":id,"rgba":data,"width":width,"height":height}));
                },
                _ => anyhow::bail!("unsupported Kitty cache format"),
            }
        }
        images.sort_by_key(|image|image["id"].as_u64());
        let mut numbers: Vec<_> = self.number_to_id.iter().map(|(number,id)|serde_json::json!({"number":number,"id":id})).collect();
        numbers.sort_by_key(|number|number["number"].as_u64());
        anyhow::ensure!(self.accumulator.len()<=128, "Kitty pending chunk limit");
        let mut commands = Vec::new();
        let mut bytes = 0;
        for image in &self.accumulator {
            let transmit = match image {
                KittyImage::TransmitData{transmit,..} => transmit,
                KittyImage::TransmitDataAndDisplay{transmit,placement,..} => {
                    anyhow::ensure!(placement.x.is_none() && placement.y.is_none() && placement.w.is_none()
                        && placement.h.is_none() && placement.x_offset.is_none() && placement.y_offset.is_none(),
                        "unsupported pending Kitty placement geometry");
                    transmit
                },
                _ => anyhow::bail!("unsupported pending Kitty action"),
            };
            anyhow::ensure!(transmit.more_data_follows && matches!(transmit.data,KittyImageData::Direct(_) | KittyImageData::DirectBin(_)),
                "unsupported pending Kitty transmission");
            let command = format!("{image}\x1b\\").into_bytes();
            bytes += command.len();
            anyhow::ensure!(bytes<=16384, "Kitty pending byte limit");
            commands.push(command);
        }
        let mut placement_buffers = Vec::new();
        for key in self.placements.keys() {
            let alternate = self.prototype_placement_buffers.get(key)
                .ok_or_else(|| anyhow::anyhow!("missing Kitty placement buffer"))?;
            placement_buffers.push(serde_json::json!({"id":key.0,"placement":key.1,"alternate":alternate}));
        }
        placement_buffers.sort_by_key(|p|(p["id"].as_u64(),p["placement"].as_u64()));
        Ok(serde_json::json!({"pendingCommands":commands,"images":images,"numbers":numbers,"placementBuffers":placement_buffers}))
    }
}

impl TerminalState {
    pub(crate) fn prototype_clear_alt_kitty(&mut self) {
        let keys: Vec<_> = self.kitty_img.placements.keys().filter(|key|
            self.kitty_img.prototype_placement_buffers.get(key) == Some(&true)).copied().collect();
        for (id,placement) in keys {
            self.kitty_remove_placement(id,placement);
            self.kitty_img.prototype_placement_buffers.remove(&(id,placement));
        }
        let unused: Vec<_> = self.kitty_img.id_to_data.keys().filter(|id|
            !self.kitty_img.placements.keys().any(|key| key.0 == **id)).copied().collect();
        for id in unused { self.kitty_img.remove_data_for_id(id); }
        let cached = &self.kitty_img.id_to_data;
        self.kitty_img.number_to_id.retain(|_,id| cached.contains_key(id));
    }
}
