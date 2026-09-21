// Host tests for the shared decoding core (Phase 1 of the plan: no Flutter,
// no camera). Run with: tool/run_native_tests.sh
//
// The cases mirror the matrix in docs/flutter_lightweight_barcode_scanner_prompt.md
// section 32, plus the buffer-layout cases that only ever show up on a real
// camera plane (row stride padding, pixel stride > 1).

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "barcode_decoder.h"
#include "fixture.h"
#include "lbs_ffi.h"

namespace {

int g_failures = 0;
int g_checks = 0;
const char* g_case = "";

void Fail(const char* file, int line, const std::string& message) {
  ++g_failures;
  std::fprintf(stderr, "  FAIL %s\n    %s:%d: %s\n", g_case, file, line,
               message.c_str());
}

void ExpectEq(const std::string& actual, const std::string& expected,
              const char* file, int line) {
  ++g_checks;
  if (actual != expected) {
    Fail(file, line, "expected \"" + expected + "\", got \"" + actual + "\"");
  }
}

void ExpectEq(long long actual, long long expected, const char* file,
              int line) {
  ++g_checks;
  if (actual != expected) {
    Fail(file, line,
         "expected " + std::to_string(expected) + ", got " +
             std::to_string(actual));
  }
}

void ExpectTrue(bool value, const char* what, const char* file, int line) {
  ++g_checks;
  if (!value) Fail(file, line, std::string("expected ") + what);
}

#define EXPECT_EQ(a, b) ExpectEq((a), (b), __FILE__, __LINE__)
#define EXPECT_TRUE(a) ExpectTrue((a), #a, __FILE__, __LINE__)

using lbs_test::Fixture;
using lbs_test::LoadFixture;
using lbs_test::Luminance;
using lbs_test::RenderOptions;

// Runs the decoder over a rendered frame exactly the way the camera path does.
std::vector<lbs::DecodeResult> Decode(const Luminance& frame,
                                      const lbs::DecodeOptions& options) {
  lbs::Decoder decoder;
  decoder.SetOptions(options);
  const std::vector<lbs::DecodeResult>& results =
      decoder.Decode(frame.data.data(), frame.data.size(), frame.width,
                     frame.height, frame.row_stride, frame.pixel_stride);
  return results;
}

lbs::DecodeOptions OptionsFor(uint32_t formats) {
  lbs::DecodeOptions options;
  options.formats = formats;
  return options;
}

// --- cases ---------------------------------------------------------------

void TestLinearSymbologies() {
  struct Case {
    const char* fixture;
    uint32_t format;
    const char* text;
  };
  const Case cases[] = {
      {"ean13", lbs::kFormatEan13, "5901234123457"},
      {"ean8", lbs::kFormatEan8, "96385074"},
      // ZXing follows ISO/IEC 15420 / GS1 and reports UPC-A content as the
      // 13 digit GTIN, i.e. with a leading zero. See README, "UPC-A values".
      {"upca", lbs::kFormatUpcA, "0036000291452"},
      {"code128", lbs::kFormatCode128, "LBS-2026-XY"},
      {"code39", lbs::kFormatCode39, "FLUTTER 42"},
      {"code93", lbs::kFormatCode93, "LIGHTWEIGHT93"},
      {"itf", lbs::kFormatItf, "1234567895"},
      {"codabar", lbs::kFormatCodabar, "A123456789B"},
  };

  for (const Case& test : cases) {
    g_case = test.fixture;
    const Fixture fixture = LoadFixture(test.fixture);
    RenderOptions render;
    render.module_size = 3;
    render.linear_height = 60;
    const Luminance frame = lbs_test::Render(fixture, render);

    const auto results = Decode(frame, OptionsFor(test.format));
    EXPECT_EQ(static_cast<long long>(results.size()), 1);
    if (!results.empty()) {
      EXPECT_EQ(results[0].text, test.text);
      EXPECT_EQ(static_cast<long long>(results[0].format), test.format);
    }
  }
}

void TestQrVariants() {
  const Fixture qr = LoadFixture("qr_text");

  {
    g_case = "qr normal";
    RenderOptions render;
    render.module_size = 8;
    const auto results = Decode(lbs_test::Render(qr, render),
                                OptionsFor(lbs::kFormatQrCode));
    EXPECT_EQ(static_cast<long long>(results.size()), 1);
    if (!results.empty()) EXPECT_EQ(results[0].text, qr.text);
  }

  {
    g_case = "qr small (2px modules)";
    RenderOptions render;
    render.module_size = 2;
    render.quiet_zone = 4;
    const auto results = Decode(lbs_test::Render(qr, render),
                                OptionsFor(lbs::kFormatQrCode));
    EXPECT_EQ(static_cast<long long>(results.size()), 1);
    if (!results.empty()) EXPECT_EQ(results[0].text, qr.text);
  }

  for (int angle : {90, 180, 270}) {
    g_case = "qr rotated";
    RenderOptions render;
    render.module_size = 6;
    render.rotate = angle;
    const auto results = Decode(lbs_test::Render(qr, render),
                                OptionsFor(lbs::kFormatQrCode));
    EXPECT_EQ(static_cast<long long>(results.size()), 1);
    if (!results.empty()) EXPECT_EQ(results[0].text, qr.text);
  }

  {
    g_case = "qr inverted";
    RenderOptions render;
    render.module_size = 6;
    render.invert = true;
    lbs::DecodeOptions options = OptionsFor(lbs::kFormatQrCode);
    options.try_invert = true;
    const auto results = Decode(lbs_test::Render(qr, render), options);
    EXPECT_EQ(static_cast<long long>(results.size()), 1);
    if (!results.empty()) EXPECT_EQ(results[0].text, qr.text);
  }

  {
    g_case = "qr inverted, try_invert off";
    RenderOptions render;
    render.module_size = 6;
    render.invert = true;
    lbs::DecodeOptions options = OptionsFor(lbs::kFormatQrCode);
    options.try_invert = false;
    const auto results = Decode(lbs_test::Render(qr, render), options);
    EXPECT_EQ(static_cast<long long>(results.size()), 0);
  }

  {
    g_case = "qr low contrast";
    RenderOptions render;
    render.module_size = 6;
    render.dark = 105;
    render.light = 150;
    const auto results = Decode(lbs_test::Render(qr, render),
                                OptionsFor(lbs::kFormatQrCode));
    EXPECT_EQ(static_cast<long long>(results.size()), 1);
    if (!results.empty()) EXPECT_EQ(results[0].text, qr.text);
  }
}

void TestDamagedSymbol() {
  g_case = "damaged qr (H error correction)";
  const Fixture qr = LoadFixture("qr_high_ec");
  RenderOptions render;
  render.module_size = 6;
  Luminance frame = lbs_test::Render(qr, render);
  // Punch out a block well inside the data region; level H tolerates ~30%.
  lbs_test::Damage(&frame, frame.width / 2, frame.height / 2, 24, 24, 128);
  const auto results = Decode(frame, OptionsFor(lbs::kFormatQrCode));
  EXPECT_EQ(static_cast<long long>(results.size()), 1);
  if (!results.empty()) EXPECT_EQ(results[0].text, qr.text);
}

void TestNoisyBarcode() {
  g_case = "noisy code128";
  const Fixture code = LoadFixture("code128");
  RenderOptions render;
  render.module_size = 4;
  render.linear_height = 80;
  render.noise_percent = 1;
  const auto results = Decode(lbs_test::Render(code, render),
                              OptionsFor(lbs::kFormatCode128));
  EXPECT_TRUE(!results.empty());
  if (!results.empty()) EXPECT_EQ(results[0].text, code.text);
}

void TestLargeFrameWithSmallSymbol() {
  g_case = "1920x1080 frame, small qr";
  const Fixture qr = LoadFixture("qr_url");
  RenderOptions render;
  render.module_size = 4;
  render.canvas_width = 1920;
  render.canvas_height = 1080;
  render.offset_x = 1400;
  render.offset_y = 760;
  lbs::DecodeOptions options = OptionsFor(lbs::kFormatQrCode);
  const auto results = Decode(lbs_test::Render(qr, render), options);
  EXPECT_EQ(static_cast<long long>(results.size()), 1);
  if (!results.empty()) EXPECT_EQ(results[0].text, qr.text);
}

void TestRegionOfInterest() {
  g_case = "region of interest";
  const Fixture wanted = LoadFixture("qr_text");
  const Fixture other = LoadFixture("qr_numeric");

  RenderOptions render;
  render.module_size = 6;
  render.canvas_width = 1280;
  render.canvas_height = 720;
  render.offset_x = 80;
  render.offset_y = 80;
  Luminance frame = lbs_test::Render(wanted, render);

  RenderOptions second = render;
  second.offset_x = 800;
  second.offset_y = 400;
  lbs_test::Compose(&frame, other, second);

  // Without a crop the decoder may pick either symbol; with a crop around the
  // first one the answer is deterministic and no pixels were copied.
  lbs::DecodeOptions options = OptionsFor(lbs::kFormatQrCode);
  options.crop_left = 40;
  options.crop_top = 40;
  options.crop_width = 400;
  options.crop_height = 400;
  const auto results = Decode(frame, options);
  EXPECT_EQ(static_cast<long long>(results.size()), 1);
  if (!results.empty()) EXPECT_EQ(results[0].text, wanted.text);

  g_case = "region of interest excludes symbol";
  options.crop_left = 600;
  options.crop_top = 40;
  options.crop_width = 160;
  options.crop_height = 160;
  EXPECT_EQ(static_cast<long long>(Decode(frame, options).size()), 0);
}

void TestMultipleBarcodes() {
  g_case = "multiple symbols in one frame";
  const Fixture qr = LoadFixture("qr_text");
  const Fixture ean = LoadFixture("ean13");

  RenderOptions render;
  render.module_size = 5;
  render.canvas_width = 960;
  render.canvas_height = 640;
  render.offset_x = 40;
  render.offset_y = 40;
  Luminance frame = lbs_test::Render(qr, render);

  RenderOptions second = render;
  second.offset_x = 40;
  second.offset_y = 360;
  second.linear_height = 100;
  lbs_test::Compose(&frame, ean, second);

  lbs::DecodeOptions options =
      OptionsFor(lbs::kFormatQrCode | lbs::kFormatEan13);
  options.max_symbols = 8;
  const auto results = Decode(frame, options);
  EXPECT_EQ(static_cast<long long>(results.size()), 2);

  bool saw_qr = false, saw_ean = false;
  for (const auto& result : results) {
    saw_qr |= result.format == lbs::kFormatQrCode && result.text == qr.text;
    saw_ean |= result.format == lbs::kFormatEan13 && result.text == ean.text;
  }
  EXPECT_TRUE(saw_qr);
  EXPECT_TRUE(saw_ean);

  g_case = "max_symbols caps the result set";
  options.max_symbols = 1;
  EXPECT_EQ(static_cast<long long>(Decode(frame, options).size()), 1);
}

void TestBufferLayouts() {
  const Fixture qr = LoadFixture("qr_text");

  {
    g_case = "padded row stride";
    RenderOptions render;
    render.module_size = 6;
    render.row_padding = 37;  // deliberately not a multiple of anything
    const auto results = Decode(lbs_test::Render(qr, render),
                                OptionsFor(lbs::kFormatQrCode));
    EXPECT_EQ(static_cast<long long>(results.size()), 1);
    if (!results.empty()) EXPECT_EQ(results[0].text, qr.text);
  }

  {
    g_case = "pixel stride 2 (interleaved plane)";
    RenderOptions render;
    render.module_size = 6;
    render.pixel_stride = 2;
    render.row_padding = 16;
    const auto results = Decode(lbs_test::Render(qr, render),
                                OptionsFor(lbs::kFormatQrCode));
    EXPECT_EQ(static_cast<long long>(results.size()), 1);
    if (!results.empty()) EXPECT_EQ(results[0].text, qr.text);
  }

  {
    g_case = "short buffer is rejected";
    RenderOptions render;
    render.module_size = 6;
    Luminance frame = lbs_test::Render(qr, render);
    lbs::Decoder decoder;
    decoder.SetOptions(OptionsFor(lbs::kFormatQrCode));
    const auto& results = decoder.Decode(
        frame.data.data(), frame.data.size() / 2, frame.width, frame.height,
        frame.row_stride, frame.pixel_stride);
    EXPECT_EQ(static_cast<long long>(results.size()), 0);
  }

  {
    g_case = "null buffer is rejected";
    lbs::Decoder decoder;
    EXPECT_EQ(static_cast<long long>(
                  decoder.Decode(nullptr, 0, 100, 100, 100, 1).size()),
              0);
  }
}

void TestViewRotationOption() {
  g_case = "rotation option matches a rotated frame";
  const Fixture qr = LoadFixture("qr_url");
  RenderOptions render;
  render.module_size = 5;
  render.rotate = 270;
  const Luminance frame = lbs_test::Render(qr, render);

  // try_rotate off: only the explicit view rotation can rescue this frame.
  lbs::DecodeOptions options = OptionsFor(lbs::kFormatQrCode);
  options.try_rotate = false;
  options.rotation = 90;
  const auto results = Decode(frame, options);
  EXPECT_EQ(static_cast<long long>(results.size()), 1);
  if (!results.empty()) EXPECT_EQ(results[0].text, qr.text);
}

void TestFormatFiltering() {
  g_case = "format filter rejects other symbologies";
  const Fixture ean = LoadFixture("ean13");
  RenderOptions render;
  render.module_size = 3;
  render.linear_height = 60;
  const Luminance frame = lbs_test::Render(ean, render);

  EXPECT_EQ(static_cast<long long>(
                Decode(frame, OptionsFor(lbs::kFormatQrCode)).size()),
            0);
  EXPECT_EQ(static_cast<long long>(
                Decode(frame, OptionsFor(lbs::kFormatEan13)).size()),
            1);

  g_case = "formats == 0 means every supported format";
  const auto results = Decode(frame, OptionsFor(0));
  EXPECT_EQ(static_cast<long long>(results.size()), 1);
  if (!results.empty()) EXPECT_EQ(results[0].text, ean.text);
}

void TestCornerPoints() {
  g_case = "corner points are inside the image";
  const Fixture qr = LoadFixture("qr_text");
  RenderOptions render;
  render.module_size = 8;
  const Luminance frame = lbs_test::Render(qr, render);
  const auto results = Decode(frame, OptionsFor(lbs::kFormatQrCode));
  EXPECT_EQ(static_cast<long long>(results.size()), 1);
  if (results.empty()) return;

  for (const lbs::Point& corner : results[0].corners) {
    EXPECT_TRUE(corner.x >= 0 && corner.x <= frame.width);
    EXPECT_TRUE(corner.y >= 0 && corner.y <= frame.height);
  }
  // The symbol sits in the middle, so no corner may touch the frame edge.
  EXPECT_TRUE(results[0].corners[0].x > 0);
  EXPECT_TRUE(results[0].corners[0].y > 0);
}

void TestDecoderReuse() {
  g_case = "one decoder, many frames";
  const Fixture qr = LoadFixture("qr_text");
  const Fixture ean = LoadFixture("ean13");
  RenderOptions qr_render;
  qr_render.module_size = 6;
  RenderOptions ean_render;
  ean_render.module_size = 3;
  ean_render.linear_height = 60;
  const Luminance qr_frame = lbs_test::Render(qr, qr_render);
  const Luminance ean_frame = lbs_test::Render(ean, ean_render);

  lbs::Decoder decoder;
  decoder.SetOptions(OptionsFor(lbs::kFormatQrCode | lbs::kFormatEan13));
  for (int i = 0; i < 20; ++i) {
    const Luminance& frame = (i % 2 == 0) ? qr_frame : ean_frame;
    const auto& results =
        decoder.Decode(frame.data.data(), frame.data.size(), frame.width,
                       frame.height, frame.row_stride, frame.pixel_stride);
    EXPECT_EQ(static_cast<long long>(results.size()), 1);
    if (!results.empty()) {
      EXPECT_EQ(results[0].text, (i % 2 == 0) ? qr.text : ean.text);
    }
  }
}

void TestFfiSurface() {
  g_case = "ffi decode + free";
  const Fixture qr = LoadFixture("qr_text");
  RenderOptions render;
  render.module_size = 6;
  const Luminance frame = lbs_test::Render(qr, render);

  LbsDecodeOptions options = {};
  options.formats = lbs::kFormatQrCode;
  options.try_harder = 1;
  options.try_rotate = 1;
  options.try_downscale = 1;
  options.max_symbols = 1;

  LbsBarcodeList* list = lbs_decode_image(
      frame.data.data(), static_cast<int64_t>(frame.data.size()), frame.width,
      frame.height, frame.row_stride, frame.pixel_stride, kLbsPixelFormatLum,
      &options);
  EXPECT_TRUE(list != nullptr);
  if (list != nullptr) {
    EXPECT_EQ(static_cast<long long>(list->count), 1);
    if (list->count == 1) {
      EXPECT_EQ(std::string(list->items[0].text), qr.text);
      EXPECT_EQ(static_cast<long long>(list->items[0].format),
                lbs::kFormatQrCode);
      EXPECT_EQ(static_cast<long long>(list->items[0].text_length),
                static_cast<long long>(qr.text.size()));
    }
    lbs_barcode_list_free(list);
  }
  lbs_barcode_list_free(nullptr);  // must be a no-op

  g_case = "ffi reports engine metadata";
  EXPECT_EQ(static_cast<long long>(lbs_supported_formats()),
            static_cast<long long>(lbs::kFormatAll));
  EXPECT_TRUE(std::strlen(lbs_engine_version()) > 0);
}

void TestRgbaInput() {
  g_case = "rgba still image";
  const Fixture qr = LoadFixture("qr_text");
  RenderOptions render;
  render.module_size = 6;
  const Luminance gray = lbs_test::Render(qr, render);

  std::vector<uint8_t> rgba(static_cast<size_t>(gray.width) * gray.height * 4);
  for (int y = 0; y < gray.height; ++y) {
    for (int x = 0; x < gray.width; ++x) {
      const uint8_t value = gray.data[static_cast<size_t>(y) * gray.row_stride + x];
      uint8_t* pixel = &rgba[(static_cast<size_t>(y) * gray.width + x) * 4];
      pixel[0] = pixel[1] = pixel[2] = value;
      pixel[3] = 255;
    }
  }

  lbs::Decoder decoder;
  decoder.SetOptions(OptionsFor(lbs::kFormatQrCode));
  const auto& results =
      decoder.Decode(rgba.data(), rgba.size(), gray.width, gray.height, 0, 0,
                     lbs::PixelFormat::kRgba);
  EXPECT_EQ(static_cast<long long>(results.size()), 1);
  if (!results.empty()) EXPECT_EQ(results[0].text, qr.text);
}

}  // namespace

int main() {
  struct Suite {
    const char* name;
    void (*run)();
  };
  const Suite suites[] = {
      {"linear symbologies", TestLinearSymbologies},
      {"qr variants", TestQrVariants},
      {"damaged symbol", TestDamagedSymbol},
      {"noisy barcode", TestNoisyBarcode},
      {"large frame", TestLargeFrameWithSmallSymbol},
      {"region of interest", TestRegionOfInterest},
      {"multiple barcodes", TestMultipleBarcodes},
      {"buffer layouts", TestBufferLayouts},
      {"view rotation", TestViewRotationOption},
      {"format filtering", TestFormatFiltering},
      {"corner points", TestCornerPoints},
      {"decoder reuse", TestDecoderReuse},
      {"rgba input", TestRgbaInput},
      {"ffi surface", TestFfiSurface},
  };

  for (const Suite& suite : suites) {
    const int before = g_failures;
    std::printf("%-24s ", suite.name);
    std::fflush(stdout);
    try {
      suite.run();
    } catch (const std::exception& error) {
      ++g_failures;
      std::fprintf(stderr, "\n  THREW %s: %s\n", suite.name, error.what());
    }
    std::printf("%s\n", g_failures == before ? "ok" : "FAILED");
  }

  std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
