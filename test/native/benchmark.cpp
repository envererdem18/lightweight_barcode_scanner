// Decode latency benchmark for the shared core.
//
// Measures what a camera frame actually costs at the three analysis
// resolutions the plugin offers, for a hit and for a miss (an empty frame is
// the common case while the user is aiming, and it is the one that has to stay
// cheap).
//
// Run with: tool/run_native_benchmark.sh

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <string>
#include <vector>

#include "barcode_decoder.h"
#include "fixture.h"

namespace {

using Clock = std::chrono::steady_clock;
using lbs_test::Fixture;
using lbs_test::Luminance;
using lbs_test::RenderOptions;

struct Stats {
  double median_ms = 0;
  double p95_ms = 0;
  double min_ms = 0;
};

Stats Measure(lbs::Decoder* decoder, const Luminance& frame, int iterations) {
  std::vector<double> samples;
  samples.reserve(iterations);
  for (int i = 0; i < iterations; ++i) {
    const auto start = Clock::now();
    decoder->Decode(frame.data.data(), frame.data.size(), frame.width,
                    frame.height, frame.row_stride, frame.pixel_stride);
    const auto end = Clock::now();
    samples.push_back(
        std::chrono::duration<double, std::milli>(end - start).count());
  }
  std::sort(samples.begin(), samples.end());
  Stats stats;
  stats.min_ms = samples.front();
  stats.median_ms = samples[samples.size() / 2];
  stats.p95_ms = samples[static_cast<size_t>(samples.size() * 0.95)];
  return stats;
}

struct Resolution {
  const char* name;
  int width;
  int height;
};

void Row(const char* label, const Resolution& resolution, const Stats& stats,
         bool found) {
  std::printf("%-22s %-11s %8.2f %8.2f %8.2f   %s\n", label, resolution.name,
              stats.median_ms, stats.p95_ms, stats.min_ms,
              found ? "hit" : "miss");
}

}  // namespace

int main() {
  const Resolution resolutions[] = {
      {"640x480", 640, 480},
      {"1280x720", 1280, 720},
      {"1920x1080", 1920, 1080},
  };
  constexpr int kIterations = 60;

  std::printf("decode latency, %d iterations per cell (milliseconds)\n\n",
              kIterations);
  std::printf("%-22s %-11s %8s %8s %8s   %s\n", "case", "resolution", "median",
              "p95", "min", "result");
  std::printf("%s\n", std::string(74, '-').c_str());

  const Fixture qr = lbs_test::LoadFixture("qr_url");
  const Fixture ean = lbs_test::LoadFixture("ean13");

  for (const Resolution& resolution : resolutions) {
    // 1. A QR code in the middle of the frame: the everyday success case.
    {
      RenderOptions render;
      render.module_size = std::max(3, resolution.width / 220);
      render.canvas_width = resolution.width;
      render.canvas_height = resolution.height;
      render.offset_x = resolution.width / 3;
      render.offset_y = resolution.height / 4;
      const Luminance frame = lbs_test::Render(qr, render);

      lbs::DecodeOptions options;
      options.formats = lbs::kFormatQrCode;
      lbs::Decoder decoder;
      decoder.SetOptions(options);
      const bool found = !decoder
                              .Decode(frame.data.data(), frame.data.size(),
                                      frame.width, frame.height,
                                      frame.row_stride, frame.pixel_stride)
                              .empty();
      Row("qr, single format", resolution, Measure(&decoder, frame, kIterations),
          found);
    }

    // 2. The same frame with every supported symbology enabled: what an app
    //    that does not narrow `formats` pays.
    {
      RenderOptions render;
      render.module_size = std::max(3, resolution.width / 220);
      render.canvas_width = resolution.width;
      render.canvas_height = resolution.height;
      render.offset_x = resolution.width / 3;
      render.offset_y = resolution.height / 4;
      const Luminance frame = lbs_test::Render(qr, render);

      lbs::DecodeOptions options;
      options.formats = lbs::kFormatAll;
      lbs::Decoder decoder;
      decoder.SetOptions(options);
      const bool found = !decoder
                              .Decode(frame.data.data(), frame.data.size(),
                                      frame.width, frame.height,
                                      frame.row_stride, frame.pixel_stride)
                              .empty();
      Row("qr, all formats", resolution, Measure(&decoder, frame, kIterations),
          found);
    }

    // 3. EAN-13, the retail case.
    {
      RenderOptions render;
      render.module_size = std::max(2, resolution.width / 480);
      render.linear_height = resolution.height / 4;
      render.canvas_width = resolution.width;
      render.canvas_height = resolution.height;
      render.offset_x = 20;
      render.offset_y = resolution.height / 4;
      const Luminance frame = lbs_test::Render(ean, render);

      lbs::DecodeOptions options;
      options.formats = lbs::kFormatEan13;
      lbs::Decoder decoder;
      decoder.SetOptions(options);
      const bool found = !decoder
                              .Decode(frame.data.data(), frame.data.size(),
                                      frame.width, frame.height,
                                      frame.row_stride, frame.pixel_stride)
                              .empty();
      Row("ean-13", resolution, Measure(&decoder, frame, kIterations), found);
    }

    // 4. An empty frame: the aiming case, and the one that decides whether the
    //    scanner feels cheap to leave running.
    {
      const Fixture blank{"blank", "none", "", 1, 1, {0}};
      RenderOptions render;
      render.module_size = 1;
      render.quiet_zone = 0;
      render.linear_height = 1;
      render.canvas_width = resolution.width;
      render.canvas_height = resolution.height;
      const Luminance frame = lbs_test::Render(blank, render);

      lbs::DecodeOptions options;
      options.formats = lbs::kFormatQrCode;
      lbs::Decoder decoder;
      decoder.SetOptions(options);
      Row("empty frame, qr only", resolution,
          Measure(&decoder, frame, kIterations), false);
    }

    // 5. A region of interest over the same empty frame, to show what the ROI
    //    buys without copying anything.
    {
      const Fixture blank{"blank", "none", "", 1, 1, {0}};
      RenderOptions render;
      render.module_size = 1;
      render.quiet_zone = 0;
      render.linear_height = 1;
      render.canvas_width = resolution.width;
      render.canvas_height = resolution.height;
      const Luminance frame = lbs_test::Render(blank, render);

      lbs::DecodeOptions options;
      options.formats = lbs::kFormatQrCode;
      options.crop_left = resolution.width / 5;
      options.crop_top = resolution.height / 3;
      options.crop_width = resolution.width * 3 / 5;
      options.crop_height = resolution.height / 3;
      lbs::Decoder decoder;
      decoder.SetOptions(options);
      Row("empty frame, 20% roi", resolution,
          Measure(&decoder, frame, kIterations), false);
    }

    std::printf("\n");
  }

  return 0;
}
