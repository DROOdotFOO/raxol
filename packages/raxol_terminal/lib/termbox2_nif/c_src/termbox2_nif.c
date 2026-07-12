#include <erl_nif.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "termbox2/termbox2.h"

// tb_init/0
static ERL_NIF_TERM nif_tb_init(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  (void)argc;
  (void)argv;
  int result = tb_init();
  return enif_make_int(env, result);
}

// tb_shutdown/0
static ERL_NIF_TERM nif_tb_shutdown(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  (void)argc;
  (void)argv;
  tb_shutdown();
  return enif_make_atom(env, "ok");
}

// tb_width/0
static ERL_NIF_TERM nif_tb_width(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  (void)argc;
  (void)argv;
  int result = tb_width();
  return enif_make_int(env, result);
}

// tb_height/0
static ERL_NIF_TERM nif_tb_height(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  (void)argc;
  (void)argv;
  int result = tb_height();
  return enif_make_int(env, result);
}

// tb_clear/0
static ERL_NIF_TERM nif_tb_clear(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  (void)argc;
  (void)argv;
  tb_clear();
  return enif_make_atom(env, "ok");
}

// tb_present/0
static ERL_NIF_TERM nif_tb_present(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  (void)argc;
  (void)argv;
  tb_present();
  return enif_make_atom(env, "ok");
}

// tb_set_cursor/2
static ERL_NIF_TERM nif_tb_set_cursor(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  (void)argc;
  (void)argv;
  int x, y;
  if (!enif_get_int(env, argv[0], &x) || !enif_get_int(env, argv[1], &y))
  {
    return enif_make_badarg(env);
  }
  tb_set_cursor(x, y);
  return enif_make_atom(env, "ok");
}

// tb_hide_cursor/0
static ERL_NIF_TERM nif_tb_hide_cursor(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  (void)argc;
  (void)argv;
  int result = tb_hide_cursor();
  return enif_make_int(env, result);
}

// tb_set_cell/5
static ERL_NIF_TERM nif_tb_set_cell(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  (void)argc;
  (void)argv;
  int x, y;
  unsigned int ch;
  unsigned int fg, bg;
  if (!enif_get_int(env, argv[0], &x) ||
      !enif_get_int(env, argv[1], &y) ||
      !enif_get_uint(env, argv[2], &ch) ||
      !enif_get_uint(env, argv[3], &fg) ||
      !enif_get_uint(env, argv[4], &bg))
  {
    return enif_make_badarg(env);
  }
  int result = tb_set_cell(x, y, ch, fg, bg);
  return enif_make_int(env, result);
}

// tb_set_input_mode/1
static ERL_NIF_TERM nif_tb_set_input_mode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  (void)argc;
  (void)argv;
  int mode;
  if (!enif_get_int(env, argv[0], &mode))
  {
    return enif_make_badarg(env);
  }
  int result = tb_set_input_mode(mode);
  return enif_make_int(env, result);
}

// tb_set_output_mode/1
static ERL_NIF_TERM nif_tb_set_output_mode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  (void)argc;
  (void)argv;
  int mode;
  if (!enif_get_int(env, argv[0], &mode))
  {
    return enif_make_badarg(env);
  }
  int result = tb_set_output_mode(mode);
  return enif_make_int(env, result);
}

// tb_print/5 (x, y, fg, bg, string)
static ERL_NIF_TERM nif_tb_print(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  (void)argc;
  (void)argv;
  int x, y;
  unsigned int fg, bg;
  ErlNifBinary bin;
  if (!enif_get_int(env, argv[0], &x) ||
      !enif_get_int(env, argv[1], &y) ||
      !enif_get_uint(env, argv[2], &fg) ||
      !enif_get_uint(env, argv[3], &bg) ||
      !enif_inspect_binary(env, argv[4], &bin))
  {
    return enif_make_badarg(env);
  }
  // Ensure null-terminated string
  char *str = (char *)malloc(bin.size + 1);
  memcpy(str, bin.data, bin.size);
  str[bin.size] = '\0';
  int result = tb_print(x, y, fg, bg, str);
  free(str);
  return enif_make_int(env, result);
}

// tb_cell_buffer/0 -> row-major list of {ch, fg, bg} for the back buffer.
// Lets Elixir read back rendered cells for reference-oracle equivalence tests.
static ERL_NIF_TERM nif_tb_cell_buffer(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  (void)argc;
  (void)argv;
  int w = tb_width();
  int h = tb_height();
  struct tb_cell *buf = tb_cell_buffer();
  if (w <= 0 || h <= 0 || buf == NULL)
  {
    return enif_make_list(env, 0);
  }
  int n = w * h;
  ERL_NIF_TERM *cells = (ERL_NIF_TERM *)malloc(sizeof(ERL_NIF_TERM) * n);
  if (cells == NULL)
  {
    return enif_make_badarg(env);
  }
  for (int i = 0; i < n; i++)
  {
    ERL_NIF_TERM ch = enif_make_uint(env, (unsigned int)buf[i].ch);
    ERL_NIF_TERM fg = enif_make_uint64(env, (ErlNifUInt64)buf[i].fg);
    ERL_NIF_TERM bg = enif_make_uint64(env, (ErlNifUInt64)buf[i].bg);
    cells[i] = enif_make_tuple3(env, ch, fg, bg);
  }
  ERL_NIF_TERM list = enif_make_list_from_array(env, cells, n);
  free(cells);
  return list;
}

// Platform-specific implementation for setting terminal title
static ERL_NIF_TERM tb_set_title(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  if (argc != 1)
  {
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "badarg"));
  }
  char title[256];
  if (enif_is_binary(env, argv[0]))
  {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin))
    {
      return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "badarg"));
    }
    if (bin.size >= sizeof(title))
    {
      return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "badarg"));
    }
    memcpy(title, bin.data, bin.size);
    title[bin.size] = '\0';
  }
  else if (enif_get_string(env, argv[0], title, sizeof(title), ERL_NIF_LATIN1))
  {
    // String was successfully converted
  }
  else
  {
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "badarg"));
  }
#ifdef _WIN32
  if (SetConsoleTitle(title))
  {
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_string(env, "set", ERL_NIF_LATIN1));
  }
  else
  {
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_string(env, "SetConsoleTitle failed", ERL_NIF_LATIN1));
  }
#else
  // Use escape sequence for Unix-like systems
  // \033]0;TITLE\007 is the standard escape sequence for setting terminal title
  if (printf("\033]0;%s\007", title) < 0)
  {
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_string(env, "Failed to set title", ERL_NIF_LATIN1));
  }
  fflush(stdout);
  return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_string(env, "set", ERL_NIF_LATIN1));
#endif
}

// Platform-specific implementation for setting terminal window position
static ERL_NIF_TERM tb_set_position(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  if (argc != 2)
  {
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "badarg"));
  }
  int x, y;
  if (!enif_get_int(env, argv[0], &x) || !enif_get_int(env, argv[1], &y))
  {
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "badarg"));
  }
  // Check for out-of-bounds values
  if (x < 0 || y < 0 || x > 32767 || y > 32767)
  {
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "badarg"));
  }
#ifdef _WIN32
  HWND hwnd = GetConsoleWindow();
  if (hwnd == NULL)
  {
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_string(env, "GetConsoleWindow failed", ERL_NIF_LATIN1));
  }
  RECT rect;
  if (!GetWindowRect(hwnd, &rect))
  {
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_string(env, "GetWindowRect failed", ERL_NIF_LATIN1));
  }
  int width = rect.right - rect.left;
  int height = rect.bottom - rect.top;
  if (MoveWindow(hwnd, x, y, width, height, TRUE))
  {
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_string(env, "set", ERL_NIF_LATIN1));
  }
  else
  {
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_string(env, "MoveWindow failed", ERL_NIF_LATIN1));
  }
#else
  // Note: Most terminals ignore this escape sequence, but we provide it
  // as a best-effort attempt to set window position
  // \033[3;Y;Xt is a non-standard escape sequence that some terminals support
  if (printf("\033[3;%d;%dt", y, x) < 0)
  {
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_string(env, "Failed to set position", ERL_NIF_LATIN1));
  }
  fflush(stdout);
  // Return a tuple indicating that position setting may not be supported
  return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_string(env, "set", ERL_NIF_LATIN1));
#endif
}

static ErlNifFunc nif_funcs[] = {
    {"tb_init", 0, nif_tb_init, 0},
    {"tb_shutdown", 0, nif_tb_shutdown, 0},
    {"tb_width", 0, nif_tb_width, 0},
    {"tb_height", 0, nif_tb_height, 0},
    {"tb_clear", 0, nif_tb_clear, 0},
    {"tb_present", 0, nif_tb_present, 0},
    {"tb_set_cursor", 2, nif_tb_set_cursor, 0},
    {"tb_hide_cursor", 0, nif_tb_hide_cursor, 0},
    {"tb_set_cell", 5, nif_tb_set_cell, 0},
    {"tb_set_input_mode", 1, nif_tb_set_input_mode, 0},
    {"tb_set_output_mode", 1, nif_tb_set_output_mode, 0},
    {"tb_print", 5, nif_tb_print, 0},
    {"tb_cell_buffer", 0, nif_tb_cell_buffer, 0},
    {"tb_set_title", 1, tb_set_title, 0},
    {"tb_set_position", 2, tb_set_position, 0}};

ERL_NIF_INIT(termbox2_nif, nif_funcs, NULL, NULL, NULL, NULL)
