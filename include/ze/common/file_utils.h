#pragma once

#include <fstream>
#include <iostream>
#include <ze/common/path_utils.h>
#include <ze/common/string_utils.h>

namespace ze {

void openFileStream(
    const std::string& filename,
    std::ifstream* fs)
{
  CHECK_NOTNULL(fs);
  CHECK(fileExists(filename)) << "File does not exist: " << filename;
  fs->open(filename.c_str(), std::ios::in);
  CHECK(*fs);
  CHECK(fs->is_open()) << "Failed to open file: " << filename;
  CHECK(!fs->eof()) << "File seems to contain no content!";
}

void openFileStreamAndCheckHeader(
    const std::string& filename,
    const std::string& header,
    std::ifstream* fs)
{
  openFileStream(filename, fs);
  std::string line;
  std::getline(*fs, line);
  CHECK_EQ(line, header) << "Invalid header.";
}

} // namespace ze
