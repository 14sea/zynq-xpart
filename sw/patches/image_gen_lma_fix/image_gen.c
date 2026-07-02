// ================================================================================ //
// NEORV32 executable image generator                                               //
// -------------------------------------------------------------------------------- //
// The NEORV32 RISC-V Processor - https://github.com/stnolting/neorv32              //
// Copyright (c) NEORV32 contributors.                                              //
// Copyright (c) 2020 - 2026 Stephan Nolting. All rights reserved.                  //
// Licensed under the BSD-3-Clause license, see LICENSE for details.                //
// SPDX-License-Identifier: BSD-3-Clause                                            //
// ================================================================================ //

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <libelf.h>
#else
#include <elf.h>
#endif

// executable signature identifier ("magic word", for bootloader only)
const uint32_t signature_c = 0x214F454E;

// output image types (operation select)
enum operation_enum {
  OP_EXE,
  OP_VHD,
  OP_BIN,
  OP_COE,
  OP_MEM,
  OP_MIF
};

// bootloader executable header
typedef struct __attribute__((packed,aligned(4))) {
  uint32_t signature;
  uint32_t base_addr;
  uint32_t size;
  uint32_t checksum;
} exe_header_t;

// ************************************************************
// Write 32-bit data to file (little-Endian).
// ************************************************************
void write32(uint32_t d, FILE *f) {

  fputc((unsigned char)((d >>  0) & 0xFF), f);
  fputc((unsigned char)((d >>  8) & 0xFF), f);
  fputc((unsigned char)((d >> 16) & 0xFF), f);
  fputc((unsigned char)((d >> 24) & 0xFF), f);
}

// ************************************************************
// Read ELF section.
// ************************************************************
void *read_section(FILE *f, Elf32_Shdr *sh) {

  void *data = malloc(sh->sh_size);
  fseek(f, sh->sh_offset, SEEK_SET);
  if (fread(data, 1, sh->sh_size, f) <= 0) {
    return NULL;
  }
  else {
    return data;
  }
}

// ************************************************************
// Show help menu.
// ************************************************************
void print_help(void){

  printf(
    "NEORV32 executable image generator\n"
    "\n"
    "Usage:    image_gen [options]\n"
    "Example:  image_gen -i main.elf -o main_exe.bin -t exe\n"
    "\n"
    "Options:\n"
    "  -h            Show this help text and exit\n"
    "  -i file_name  ELF input file\n"
    "  -o file_name  Image output file\n"
    "  -t format     Image output format\n"
    "\n"
    "Image formats (using little-Endian byte ordering):\n"
    "  exe  Executable for bootloader upload (binary file with header) \n"
    "  vhd  VHDL memory image (raw executable)\n"
    "  bin  Binary file (raw executable)\n"
    "  coe  COE file (8x hex per line, ASCII, raw executable)\n"
    "  mem  MEM file (8x hex per line, ASCII, raw executable)\n"
    "  mif  MIF file (8x hex per line, ASCII, raw executable)\n"
  );
}

// ************************************************************
// Main.
// ************************************************************
int main(int argc, char *argv[]) {

  FILE *input = NULL, *output = NULL;
  char *input_file = NULL, *output_file = NULL, tmp_string[1024];
  uint32_t checksum = 0;
  int arg_i = 0;
  unsigned int i = 0, operation = OP_EXE, raw_exe_size = 0, ext_exe_size = 0;

  // show help menu if there are no arguments
  if (argc <= 1) {
    print_help();
    return 0;
  }

  // ****************************************
  // parse arguments
  // ****************************************
  for (arg_i = 1; arg_i < argc; arg_i++) {
    // show help
    if (strcmp(argv[arg_i], "-h") == 0) {
      print_help();
      return 0;
    }
    // input file
    else if (strcmp(argv[arg_i], "-i") == 0) {
      input_file = argv[++arg_i];
    }
    // output file
    else if (strcmp(argv[arg_i], "-o") == 0) {
      output_file = argv[++arg_i];
    }
    // type
    else if (strcmp(argv[arg_i], "-t") == 0) {
      arg_i++;
      if      (strcmp(argv[arg_i], "exe") == 0) { operation = OP_EXE; }
      else if (strcmp(argv[arg_i], "vhd") == 0) { operation = OP_VHD; }
      else if (strcmp(argv[arg_i], "bin") == 0) { operation = OP_BIN; }
      else if (strcmp(argv[arg_i], "coe") == 0) { operation = OP_COE; }
      else if (strcmp(argv[arg_i], "mem") == 0) { operation = OP_MEM; }
      else if (strcmp(argv[arg_i], "mif") == 0) { operation = OP_MIF; }
      else {
        printf("[ERROR] Invalid type '%s'!\n", argv[arg_i]);
        return -1;
      }
    }
    // invalid
    else {
      printf("[ERROR] Invalid flag '%s'!\n", argv[arg_i]);
      return -1;
    }
  }

  // ****************************************
  // open input/output files
  // ****************************************
  input = fopen(input_file, "rb");
  if (input == NULL) {
    printf("[ERROR] Input file error (%s)!\n", input_file);
    return -2;
  }

  output = fopen(output_file, "wb");
  if (output == NULL) {
    printf("[ERROR] Output file error (%s)!\n", output_file);
    fclose(output);
    return -2;
  }

  // ****************************************
  // parse ELF
  // ****************************************

  Elf32_Ehdr elf;
  if (fread(&elf, 1, sizeof(elf), input) <= 0) {
    printf("[ERROR] Input file is empty (%s)!\n", input_file);
    return -2;
  }

  if (memcmp(elf.e_ident, ELFMAG, SELFMAG) != 0) {
    printf("[ERROR] Input file is not an ELF (%s)!\n", input_file);
    return -2;
  }

  // base address (= entry point)
  uint32_t base_addr = (uint32_t)elf.e_entry;

  // ****************************************
  // build the raw ROM image from the ELF PROGRAM HEADERS (PT_LOAD)
  // ****************************************
  // The ROM image must be the ELF *load image*: every PT_LOAD segment placed at
  // its load address (p_paddr), gaps zero-filled. Iterating sections (.text/
  // .rodata/.data) and concatenating them is wrong: it drops the alignment gaps
  // the linker leaves between sections (e.g. a 4-byte pad before an ALIGN(8)
  // .rodata), shifting everything after the gap relative to its linked address.
  // Only p_filesz bytes are copied per segment (BSS: p_memsz > p_filesz is
  // runtime-zeroed RAM, never part of the ROM image).

  Elf32_Phdr *phdrs = malloc(elf.e_phentsize * elf.e_phnum);
  if (!phdrs) {
    printf("[ERROR] malloc failed!\n");
    return -1;
  }
  fseek(input, elf.e_phoff, SEEK_SET);
  if (fread(phdrs, elf.e_phentsize, elf.e_phnum, input) <= 0) {
    printf("[ERROR] Input file read error (%s)!\n", input_file);
    return -2;
  }

  uint32_t load_base = 0xFFFFFFFFu, load_end = 0;
  for (i = 0; i < elf.e_phnum; i++) {
    if (phdrs[i].p_type != PT_LOAD || phdrs[i].p_filesz == 0) {
      continue;
    }
    if ((uint32_t)phdrs[i].p_paddr < load_base) {
      load_base = (uint32_t)phdrs[i].p_paddr;
    }
    if ((uint32_t)phdrs[i].p_paddr + (uint32_t)phdrs[i].p_filesz > load_end) {
      load_end = (uint32_t)phdrs[i].p_paddr + (uint32_t)phdrs[i].p_filesz;
    }
  }
  if (load_end <= load_base) {// no PT_LOAD content?
    printf("[ERROR] Image is empty!\n");
    return -2;
  }
  raw_exe_size = load_end - load_base;
  if ((raw_exe_size % 4) != 0) {
    printf("[WARNING] Image size is not a multiple of 4 bytes!\n");
  }

  // make sure memory array is a power of two
  ext_exe_size = 4;
  while (ext_exe_size < raw_exe_size) {
    ext_exe_size *= 2;
  }

  // construct raw image: zero-filled, each PT_LOAD at (p_paddr - base)
  uint8_t *raw_image = calloc(raw_exe_size, 1);
  uint32_t *raw_image32 = (uint32_t *)raw_image;
  if (!raw_image) {
    printf("[ERROR] malloc failed!\n");
    return -1;
  }
  for (i = 0; i < elf.e_phnum; i++) {
    if (phdrs[i].p_type != PT_LOAD || phdrs[i].p_filesz == 0) {
      continue;
    }
    fseek(input, phdrs[i].p_offset, SEEK_SET);
    if (fread(raw_image + ((uint32_t)phdrs[i].p_paddr - load_base), 1,
              phdrs[i].p_filesz, input) != phdrs[i].p_filesz) {
      printf("[ERROR] Input file read error (%s)!\n", input_file);
      return -2;
    }
  }
  fclose(input);

  // --------------------------------------------------------------------------
  // executable for bootloader upload (including header)
  // --------------------------------------------------------------------------
  if (operation == OP_EXE) {

    exe_header_t header;

    // reserve header space
    for (i = 0; i < sizeof(header); i++) {
      fputc(0, output);
    }

    // actual data and checksum
    checksum = 0;
    for (i = 0; i < raw_exe_size/4; i++) {
      checksum += raw_image32[i];
      write32(raw_image32[i], output);
    }

    // setup header
    rewind(output);
    header.signature = signature_c;
    header.base_addr = base_addr;
    header.size      = raw_exe_size;
    header.checksum  = ~checksum;
    write32(header.signature, output);
    write32(header.base_addr, output);
    write32(header.size, output);
    write32(header.checksum, output);

    // report
    printf("Executable (EXE): %d bytes @ 0x%08X, checksum = 0x%08X\n",
           (unsigned int)header.size, (unsigned int)header.base_addr, (unsigned int)header.checksum);
  }

  // --------------------------------------------------------------------------
  // VHDL memory image (package name = output file name)
  // --------------------------------------------------------------------------
  else if (operation == OP_VHD) {

    // remove path from output file
    const char *filename = strrchr(output_file, '/'); // Linux
    if (filename == NULL) {
      filename = strrchr(output_file, '\\'); // maybe Windows?
    }
    if (filename) {
      filename++;
    }
    else {
      filename = output_file;
    }

    // remove suffix from output file
    char pkg_name[256];
    strncpy(pkg_name, filename, sizeof(pkg_name));
    pkg_name[sizeof(pkg_name)-1] = '\0';

    char *suffix = strrchr(pkg_name, '.');
    if (suffix) {
      *suffix = '\0';
    }

    // header
    snprintf(tmp_string, sizeof(tmp_string),
      "library ieee;\n"
      "use ieee.std_logic_1164.all;\n"
      "\n"
      "package %s is\n"
      "\n"
      "type rom_t is array (0 to %u) of std_ulogic_vector(31 downto 0);\n"
      "constant image_size_c : natural := %u;\n"
      "constant image_data_c : rom_t := (\n",
      pkg_name, (ext_exe_size/4)-1, raw_exe_size);
    fputs(tmp_string, output);

    // data
    for (i = 0; i < raw_exe_size/4; i++) {
      snprintf(tmp_string, sizeof(tmp_string), "x\"%08x\",\n", (unsigned int)raw_image32[i]);
      fputs(tmp_string, output);
    }

    // end
    snprintf(tmp_string, sizeof(tmp_string),
      "others => (others => '0')\n"
      ");\n"
      "\n"
      "end %s;\n", pkg_name);
    fputs(tmp_string, output);

    // report
    printf("Executable (VHD): %d bytes\n", raw_exe_size);
  }

  // --------------------------------------------------------------------------
  // executable plain-binary file
  // --------------------------------------------------------------------------
  else if (operation == OP_BIN) {

    for (i = 0; i < raw_exe_size; i++) {
      fputc((unsigned char)(raw_image[i]), output);
    }

    // report
    printf("Executable (BIN): %d bytes\n", raw_exe_size);
  }

  // --------------------------------------------------------------------------
  // executable COE file
  // --------------------------------------------------------------------------
  else if (operation == OP_COE) {

    // header
    snprintf(tmp_string, sizeof(tmp_string), "memory_initialization_radix=16;\n");
    fputs(tmp_string, output);
    snprintf(tmp_string, sizeof(tmp_string), "memory_initialization_vector=\n");
    fputs(tmp_string, output);

    for (i = 0; i < raw_exe_size/4; i++) {
      if (i == ((raw_exe_size/4)-1)) {
        snprintf(tmp_string, sizeof(tmp_string), "%08x;\n", (unsigned int)raw_image32[i]);
      }
      else {
        snprintf(tmp_string, sizeof(tmp_string), "%08x,\n", (unsigned int)raw_image32[i]);
      }
      fputs(tmp_string, output);
    }

    // report
    printf("Executable (COE): %d bytes\n", raw_exe_size);
  }

  // --------------------------------------------------------------------------
  // executable MEM file
  // --------------------------------------------------------------------------
  else if (operation == OP_MEM) {

    for (i = 0; i < raw_exe_size/4; i++) {
      snprintf(tmp_string, sizeof(tmp_string), "@%08x %08x\n", (unsigned int)i, (unsigned int)raw_image32[i]);
      fputs(tmp_string, output);
    }

    // report
    printf("Executable (MEM): %d bytes\n", raw_exe_size);
  }

  // --------------------------------------------------------------------------
  // executable MIF file
  // --------------------------------------------------------------------------
  else if (operation == OP_MIF) {

    // header
    snprintf(tmp_string, sizeof(tmp_string), "DEPTH = %u;\n", raw_exe_size/4); // memory depth in words
    fputs(tmp_string, output);
    snprintf(tmp_string, sizeof(tmp_string), "WIDTH = 32;\n"); // bits per data word
    fputs(tmp_string, output);
    snprintf(tmp_string, sizeof(tmp_string), "ADDRESS_RADIX = HEX;\n"); // hexadecimal address format
    fputs(tmp_string, output);
    snprintf(tmp_string, sizeof(tmp_string), "DATA_RADIX = HEX;\n"); // hexadecimal data format
    fputs(tmp_string, output);

    snprintf(tmp_string, sizeof(tmp_string), "CONTENT\n");
    fputs(tmp_string, output);
    snprintf(tmp_string, sizeof(tmp_string), "BEGIN\n");
    fputs(tmp_string, output);

    for (i = 0; i < raw_exe_size/4; i++) {
      snprintf(tmp_string, sizeof(tmp_string), "%08x : %08x;\n", (unsigned int)i, (unsigned int)raw_image32[i]);
      fputs(tmp_string, output);
    }

    // footer
    snprintf(tmp_string, sizeof(tmp_string), "END;\n");
    fputs(tmp_string, output);

    // report
    printf("Executable (MIF): %d bytes\n", raw_exe_size);
  }

  // invalid operation
  else {
    printf("[ERROR] Invalid operation!\n");
    free(raw_image);
    free(phdrs);
    fclose(output);
    return -1;
  }

  // clean up
  free(raw_image);
  free(phdrs);
  fclose(output);

  return 0;
}
