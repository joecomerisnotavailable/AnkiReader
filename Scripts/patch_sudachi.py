from pathlib import Path
p=Path('Vendor/sudachi/sudachi/src/plugin/loader.rs')
s=p.read_text()
s=s.replace('#[cfg(target_os = "macos")]', '#[cfg(any(target_os = "macos", target_os = "ios"))]')
p.write_text(s)
