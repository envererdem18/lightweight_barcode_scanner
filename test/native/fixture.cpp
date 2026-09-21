#include "fixture.h"

#include <algorithm>
#include <fstream>
#include <sstream>
#include <stdexcept>

namespace lbs_test {
namespace {

// Set by the test main() from the value CMake baked in.
const char* FixtureDir() {
#ifdef LBS_FIXTURE_DIR
  return LBS_FIXTURE_DIR;
#else
  return "fixtures";
#endif
}

struct Grid {
  int width = 0;
  int height = 0;
  std::vector<uint8_t> cells;
  uint8_t at(int x, int y) const { return cells[y * width + x]; }
};

Grid Rotate(const Grid& in, int degrees) {
  Grid out;
  switch (((degrees % 360) + 360) % 360) {
    case 90:
      out.width = in.height;
      out.height = in.width;
      out.cells.resize(in.cells.size());
      for (int y = 0; y < in.height; ++y)
        for (int x = 0; x < in.width; ++x)
          out.cells[x * out.width + (out.width - 1 - y)] = in.at(x, y);
      return out;
    case 180:
      out.width = in.width;
      out.height = in.height;
      out.cells.resize(in.cells.size());
      for (int y = 0; y < in.height; ++y)
        for (int x = 0; x < in.width; ++x)
          out.cells[(in.height - 1 - y) * out.width + (in.width - 1 - x)] =
              in.at(x, y);
      return out;
    case 270:
      out.width = in.height;
      out.height = in.width;
      out.cells.resize(in.cells.size());
      for (int y = 0; y < in.height; ++y)
        for (int x = 0; x < in.width; ++x)
          out.cells[(out.height - 1 - x) * out.width + y] = in.at(x, y);
      return out;
    default:
      return in;
  }
}

// Expands the module grid to pixels, including the quiet zone.
Grid ToPixels(const Fixture& fixture, const RenderOptions& options) {
  const bool linear = fixture.height == 1;
  const int rows =
      linear ? std::max(1, options.linear_height / std::max(1, options.module_size))
             : fixture.height;

  Grid pixels;
  const int quiet = options.quiet_zone;
  pixels.width = (fixture.width + 2 * quiet) * options.module_size;
  pixels.height = (rows + 2 * quiet) * options.module_size;
  pixels.cells.assign(static_cast<size_t>(pixels.width) * pixels.height, 0);

  for (int my = 0; my < rows; ++my) {
    for (int mx = 0; mx < fixture.width; ++mx) {
      if (!fixture.at(mx, linear ? 0 : my)) continue;
      const int px = (mx + quiet) * options.module_size;
      const int py = (my + quiet) * options.module_size;
      for (int dy = 0; dy < options.module_size; ++dy)
        for (int dx = 0; dx < options.module_size; ++dx)
          pixels.cells[(py + dy) * pixels.width + px + dx] = 1;
    }
  }
  return Rotate(pixels, options.rotate);
}

void Blit(Luminance* frame, const Grid& pixels, const RenderOptions& options) {
  const uint8_t dark = options.invert ? options.light : options.dark;
  const uint8_t light = options.invert ? options.dark : options.light;

  for (int y = 0; y < pixels.height; ++y) {
    const int fy = y + options.offset_y;
    if (fy < 0 || fy >= frame->height) continue;
    for (int x = 0; x < pixels.width; ++x) {
      const int fx = x + options.offset_x;
      if (fx < 0 || fx >= frame->width) continue;
      frame->data[static_cast<size_t>(fy) * frame->row_stride +
                  static_cast<size_t>(fx) * frame->pixel_stride] =
          pixels.at(x, y) ? dark : light;
    }
  }
}

void AddNoise(Luminance* frame, const RenderOptions& options) {
  if (options.noise_percent <= 0) return;
  uint32_t state = options.noise_seed ? options.noise_seed : 1;
  const size_t pixels = static_cast<size_t>(frame->width) * frame->height;
  const size_t count = pixels * options.noise_percent / 100;
  for (size_t i = 0; i < count; ++i) {
    state = state * 1664525u + 1013904223u;
    const int x = static_cast<int>((state >> 16) % frame->width);
    state = state * 1664525u + 1013904223u;
    const int y = static_cast<int>((state >> 16) % frame->height);
    frame->data[static_cast<size_t>(y) * frame->row_stride +
                static_cast<size_t>(x) * frame->pixel_stride] =
        (state & 0x100) ? 0 : 255;
  }
}

}  // namespace

Fixture LoadFixture(const std::string& name) {
  const std::string path = std::string(FixtureDir()) + "/" + name + ".txt";
  std::ifstream file(path);
  if (!file) throw std::runtime_error("cannot open fixture: " + path);

  Fixture fixture;
  fixture.name = name;
  std::string line;
  while (std::getline(file, line)) {
    if (line.empty() || line[0] == '#') continue;
    if (line.rfind("format ", 0) == 0) {
      fixture.format = line.substr(7);
    } else if (line.rfind("text ", 0) == 0) {
      fixture.text = line.substr(5);
    } else if (line.rfind("size ", 0) == 0) {
      std::istringstream in(line.substr(5));
      in >> fixture.width >> fixture.height;
      fixture.modules.reserve(static_cast<size_t>(fixture.width) *
                              fixture.height);
    } else {
      for (char c : line) fixture.modules.push_back(c == '1' ? 1 : 0);
    }
  }
  if (fixture.width <= 0 ||
      fixture.modules.size() !=
          static_cast<size_t>(fixture.width) * fixture.height) {
    throw std::runtime_error("malformed fixture: " + path);
  }
  return fixture;
}

Luminance Render(const Fixture& fixture, const RenderOptions& options) {
  const Grid pixels = ToPixels(fixture, options);

  Luminance frame;
  frame.width = options.canvas_width > 0 ? options.canvas_width : pixels.width;
  frame.height =
      options.canvas_height > 0 ? options.canvas_height : pixels.height;
  frame.pixel_stride = std::max(1, options.pixel_stride);
  frame.row_stride = frame.width * frame.pixel_stride + options.row_padding;
  // A recognisable filler makes stride bugs show up as decode failures rather
  // than as accidentally-correct reads.
  frame.data.assign(static_cast<size_t>(frame.row_stride) * frame.height,
                    options.invert ? options.dark : options.light);

  Blit(&frame, pixels, options);
  AddNoise(&frame, options);
  return frame;
}

void Compose(Luminance* frame, const Fixture& fixture,
             const RenderOptions& options) {
  Blit(frame, ToPixels(fixture, options), options);
}

void Damage(Luminance* frame, int x, int y, int width, int height,
            uint8_t value) {
  for (int dy = 0; dy < height; ++dy) {
    const int fy = y + dy;
    if (fy < 0 || fy >= frame->height) continue;
    for (int dx = 0; dx < width; ++dx) {
      const int fx = x + dx;
      if (fx < 0 || fx >= frame->width) continue;
      frame->data[static_cast<size_t>(fy) * frame->row_stride +
                  static_cast<size_t>(fx) * frame->pixel_stride] = value;
    }
  }
}

}  // namespace lbs_test
