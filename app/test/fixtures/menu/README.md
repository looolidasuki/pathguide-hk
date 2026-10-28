# Menu OCR regression fixtures

These JSON files are OCR output from the two menu images supplied by the user on
2026-10-23 (360 × 488 dense menu; 360 × 507 tea menu). Images are not copied into
the repository. Restaurant text and prices are test examples, not current offers.

Generated on macOS with the same `ios/Runner/MenuOCR.swift` used by the iOS app:

```sh
swiftc -module-cache-path /private/tmp/pathguide-swift-module-cache \
  ios/Runner/MenuOCR.swift tool/menu_ocr_probe.swift -o /private/tmp/menu-ocr-probe
/private/tmp/menu-ocr-probe /private/tmp/menu-output image1.jpeg image2.jpeg
```

The probe accepts upright images. The iOS plugin separately honours UIImage/EXIF
orientation. Probe host timings and observation counts do not measure iPhone
performance, accuracy or end-to-end speech behaviour. The dense image still has
missing and incorrect Chinese characters. The tea image specifically tests
sandwich variants, supplements, full-width currency and bracketed price ambiguity.

`tea-menu.price-crops.macos-vision.json` records the contextual grayscale price
pass (`2026-10-23.price-crops.1`). It remains a macOS OCR fixture, not a phone
record. The previous fixtures are retained for regression.

`dense-menu.iphone-selected.json` selects verbatim text/geometry from the user's
220-line iPhone diagnostic report. It is not a fresh Mac OCR result and not the
complete report. Confidence was not supplied; fixture confidence=1 is a placeholder
for geometry tests only. It reproduces vertical-box interference, covered glyphs,
three price columns and a split dish suffix.
