// Retained resources are read from actual image cells, not from output history.
#[derive(Default)]
struct BridgeGraphics {
    resources: std::collections::BTreeMap<String, BridgeValue>,
    decoded_bytes: usize,
}

impl BridgeGraphics {
    fn row(&mut self, line: &wezterm_surface::Line, cell_width: usize, cell_height: usize,
        requests: &std::collections::HashMap<([u8;32],usize,usize),BridgeValue>) -> anyhow::Result<Vec<BridgeValue>> {
        let mut placements = std::collections::BTreeMap::new();
        for cell in line.visible_cells() {
            for img in cell.attrs().images().unwrap_or_default() {
                let tl = img.top_left(); let br = img.bottom_right();
                let (left,top,right,bottom) = img.padding();
                anyhow::ensure!(left==0 && top==0 && cell_width>right as usize && cell_height>bottom as usize,
                    "unsupported image padding");
                let dx = br.x.into_inner() - tl.x.into_inner();
                let dy = br.y.into_inner() - tl.y.into_inner();
                anyhow::ensure!(dx>0.0 && dy>0.0, "invalid image texture range");
                let display_width = ((cell_width-right as usize) as f64/dx as f64).round() as usize;
                let display_height = ((cell_height-bottom as usize) as f64/dy as f64).round() as usize;
                anyhow::ensure!((1..=2048).contains(&display_width) && (1..=2048).contains(&display_height), "image display limit");
                let column_offset = (tl.x.into_inner() as f64*display_width as f64/cell_width as f64).round() as usize;
                let stripe = (tl.y.into_inner() as f64*display_height as f64/cell_height as f64).round() as usize;
                let column = cell.cell_index().checked_sub(column_offset).ok_or_else(||anyhow::anyhow!("image origin clipped"))?;
                if img.image_id().is_some() {
                    anyhow::ensure!(img.placement_id().is_some(), "unsupported automatic Kitty placement identity");
                }
                let key = format!("{}-{}-{}", hex::encode(img.image_data().hash()),display_width,display_height);
                if !self.resources.contains_key(&key) {
                    anyhow::ensure!(self.resources.len()<32, "image resource count limit");
                    use wezterm_cell::image::ImageDataType;
                    let data = img.image_data().data();
                    let (rgba,encoded,width,height) = match &*data {
                        ImageDataType::Rgba8{data,width,height,..} => {
                            anyhow::ensure!(data.len()<=262144usize.saturating_sub(self.decoded_bytes), "checkpoint image byte limit");
                            (data.clone(),Vec::new(),*width,*height)
                        },
                        ImageDataType::EncodedFile(bytes) => {
                            let reader = ::image::io::Reader::new(std::io::Cursor::new(bytes)).with_guessed_format()?;
                            let (w,h) = reader.into_dimensions()?;
                            anyhow::ensure!(w>0 && h>0 && w<=2048 && h<=2048 && w as usize*h as usize<=65536,
                                "checkpoint image dimensions");
                            anyhow::ensure!(w as usize*h as usize*4<=262144usize.saturating_sub(self.decoded_bytes), "checkpoint image byte limit");
                            anyhow::ensure!(bytes.len()<=262144, "checkpoint encoded image byte limit");
                            (Vec::new(),bytes.clone(),w,h)
                        },
                        _ => anyhow::bail!("unsupported animated or leased image resource"),
                    };
                    anyhow::ensure!(width>0 && height>0 && width<=2048 && height<=2048
                        && (!encoded.is_empty() || rgba.len()==width as usize*height as usize*4), "image resource dimensions");
                    self.decoded_bytes = self.decoded_bytes.checked_add(width as usize*height as usize*4).ok_or_else(||anyhow::anyhow!("image budget overflow"))?;
                    anyhow::ensure!(self.decoded_bytes<=262144, "checkpoint image byte limit");
                    anyhow::ensure!((encoded.is_empty() && img.image_id().is_none()) ||
                        requests.contains_key(&(img.image_data().hash(),display_width,display_height)),
                        "image request metadata limit");
                    self.resources.insert(key.clone(),json!({"key":key,"rgba":rgba,"encoded":encoded,"width":width,"height":height,
                        "displayWidth":display_width,"displayHeight":display_height,
                        "request":requests.get(&(img.image_data().hash(),display_width,display_height))}));
                }
                let placement_key = (key.clone(),column,stripe,img.image_id(),img.placement_id(),img.z_index());
                placements.entry(placement_key).or_insert_with(||json!({"resource":key,"column":column,"stripe":stripe,
                    "imageId":img.image_id(),"placementId":img.placement_id(),"zIndex":img.z_index()}));
            }
        }
        Ok(placements.into_values().collect())
    }
}
