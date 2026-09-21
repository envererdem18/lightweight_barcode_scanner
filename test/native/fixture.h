// Test-only helpers: turn a module-pattern fixture into a luminance buffer
// that looks like something a camera would hand us.
#ifndef LBS_TEST_FIXTURE_H_
#define LBS_TEST_FIXTURE_H_

#include <cstdint>
#include <string>
#include <vector>

namespace lbs_test {

// A symbol as a grid of modules. Linear symbologies have height == 1.
struct Fixture {
  std::string name;
  std::string format;
  std::string text;
  int width = 0;
  int height = 0;
  std::vector<uint8_t> modules;  // 1 == dark

  uint8_t at(int x, int y) const { return modules[y * width + x]; }
};

Fixture LoadFixture(const std::string& name);

struct RenderOptions {
  int module_size = 4;     // pixels per module
  int quiet_zone = 6;      // modules of quiet zone around the symbol
  int linear_height = 40;  // pixel height of a 1D symbol's bars
  uint8_t dark = 0;
  uint8_t light = 255;
  bool invert = false;
  int rotate = 0;          // 0/90/180/270, clockwise
  // Place the rendered symbol inside a larger frame. 0 means "tight".
  int canvas_width = 0;
  int canvas_height = 0;
  int offset_x = 0;
  int offset_y = 0;
  // Camera buffers are rarely tightly packed.
  int row_padding = 0;     // extra bytes at the end of every row
  int pixel_stride = 1;    // >1 simulates an interleaved plane
  // Deterministic salt & pepper noise, in percent of pixels.
  int noise_percent = 0;
  uint32_t noise_seed = 1;
};

// An 8-bit luminance image, laid out like a camera plane.
struct Luminance {
  std::vector<uint8_t> data;
  int width = 0;
  int height = 0;
  int row_stride = 0;
  int pixel_stride = 1;
};

Luminance Render(const Fixture& fixture, const RenderOptions& options);

// Composites a second symbol into an existing frame (multi-barcode tests).
void Compose(Luminance* frame, const Fixture& fixture,
             const RenderOptions& options);

// Erases a rectangle of modules (damaged-symbol tests).
void Damage(Luminance* frame, int x, int y, int width, int height,
            uint8_t value);

}  // namespace lbs_test

#endif  // LBS_TEST_FIXTURE_H_
