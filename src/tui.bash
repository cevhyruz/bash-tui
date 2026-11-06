# shellcheck shell=bash
# vi: fdm=marker
#
# tui.bash - terminal user interface toolkit for bash.
# Usage: source tui.bash
#
# MIT License
#
# Copyright (c) 2026 John Fred Fadrigalan
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# The latest version of this software can be obtained here:
# https://github.com/cevhyruz/bash-tui

# We require bash 4.2+.
if [[ -z "${BASH_VERSION:-}" ]] ||
   [[ "${BASH_VERSINFO[0]}" -lt 4 ]] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  printf 'tui.bash: requires bash 4.2 or newer (this is %s)\n' \
    "${BASH_VERSION:-not bash}" >&2
  return 1 2>/dev/null
fi

# guard against double sourcing
[[ -n ${_TUI_LOADED:-} ]] && return 0
_TUI_LOADED=1

_TUI_BASH_VERSINFO=( 0 1 0 )

# for linking as shared library
export _TUI_SOURCEPATH="${BASH_SOURCE[0]}"

_TUI_ROWS=0 _TUI_COLS=0
_TUI_RESIZED=0        # set by the WINCH trap

_TUI_STTY_SETTINGS="" # stores current stty settings
_TUI_KEY=""           # named key parsed by the _tui_parse_key
_TUI_TICK=0.05        # wake-up interval, used when something needs polling
_TUI_TITLE_PUSHED=0   # 1 while a title is saved on the terminal's stack
_TUI_TITLE=""         # the last title set by user for restoration on suspend
_TUI_SUSPEND=0        # set by the TSTP trap, handled by the main loop


# Prepare the terminal for full-screen drawing.
_tui_init() {
  _TUI_STTY_SETTINGS=$(stty -g 2>/dev/null)
  _tui_setup_term
  shopt -s checkwinsize
  _tui_get_size_env || _tui_get_tty_size
}

# Put the terminal into full-screen mode.
_tui_setup_term() {
  _tui_title_push
  if [[ -n $_TUI_TITLE ]]; then
    printf '\e]0;%s\a' "$_TUI_TITLE"
  fi
  # \e[?1049h: enter alternate screen
  #   \e[?25l: hide cursor
  #    \e[?7l: disable line wrap
  #     \e[2J: clear screen
  #      \e[H: cursor
  printf '\e[?1049h\e[?25l\e[?7l\e[2J\e[H'
  # Disables echo and line buffering so input arrives byte by byte as typed,
  # returning as soon as 1 byte is available with no timeout.
  stty -echo -icanon min 1 time 0 2>/dev/null
}

# Restore the terminal settings saved at startup, if none were saved, just
# re-enable echo and line-buffering.
_tui_deinit() {
  # \e[?1000l: disable normal mouse tracking
  #    \e[?7h: enable line wrap
  #   \e[?25h: show cursor
  # \e[?1049l: switch back to the main screen buffer
  printf '\e[?1000l\e[?7h\e[?25h\e[?1049l'
  _tui_title_pop
  if [[ -n $_TUI_STTY_SETTINGS ]]; then
    stty "$_TUI_STTY_SETTINGS" 2>/dev/null
  else
    stty echo icanon 2>/dev/null
  fi
}

# Query the terminal size and sets _TUI_ROWS and _TUI_COLS.
_tui_get_tty_size() {
  local size
  size=$(stty size 2>/dev/null </dev/tty) || size="24 80"
  _TUI_ROWS=${size% *}
  _TUI_COLS=${size#* }
}

# Sets _TUI_ROWS and _TUI_COLS from bash's own LINES/COLUMNS (faster, no fork).
_tui_get_size_env() {
  (:;:) # with 'checkwinsize', bash checks the window size only after an
        # external (non-builtin) command.
  (( ${LINES:-0} > 0 && ${COLUMNS:-0} > 0 )) || return 1
  _TUI_ROWS=$LINES _TUI_COLS=$COLUMNS
}

# Sets the trap that signals to resize.
_tui_trap_resize() {
  trap '_TUI_RESIZED=1' WINCH
}

# Removes the resize trap and clears any pending resize.
_tui_untrap_resize() {
  trap - WINCH
  _TUI_RESIZED=0
}

# True if a resize was pending. clears the flag and re-reads the size.
_tui_resize_check() {
  (( _TUI_RESIZED )) || return 1
  _TUI_RESIZED=0
  _tui_get_size_env
}

# Give the terminal back to the shell and stop this process, as Ctrl-Z would
# for any program. Call from the main loop, not from inside a trap.
_tui_suspend() {
  _tui_deinit
  trap - TSTP               # default action, so the kill really stops us
  kill -TSTP $$             # frozen here until the shell sends SIGCONT
  _tui_trap_suspend         # continued (fg): re-arm, then rebuild the screen
  _tui_resume
}

# Re-enter full-screen mode after a suspend. The original stty settings saved
# by _tui_init are kept, so the final _tui_deinit still restores the user's.
_tui_resume() {
  _tui_setup_term
  _tui_get_tty_size
  _TUI_RESIZED=1 # the size may have changed while stopped; forces a redraw
}

_tui_trap_suspend() {
  trap '_TUI_SUSPEND=1' TSTP
}

_tui_untrap_suspend() {
  trap - TSTP
  _TUI_SUSPEND=0
}

# True if a suspend was requested.
_tui_suspend_check() {
  (( _TUI_SUSPEND )) || return 1
  _TUI_SUSPEND=0
  _tui_suspend
}

# Save the current terminal title so _tui_title_pop can restore it.
_tui_title_push() {
  (( _TUI_TITLE_PUSHED )) && return 0
  printf '\e[22;0t'
  _TUI_TITLE_PUSHED=1
}

# Restore the title saved by _tui_title_push, if any.
_tui_title_pop() {
  (( _TUI_TITLE_PUSHED )) || return 0
  printf '\e[23;0t'
  _TUI_TITLE_PUSHED=0
}

# Set the terminal title (icon name and window title).
_tui_title_set() {
  _TUI_TITLE=${1//[[:cntrl:]]/}
  printf '\e]0;%s\a' "$_TUI_TITLE"
}

# Set the process name shown by pgrep/ps/top (Linux only, max 15 characters).
_tui_set_name() {
  [[ -w /proc/$$/comm ]] || return 1
  printf '%s' "${1:0:15}" > "/proc/$$/comm"
}

# Read one key into _TUI_KEY. TIMEOUT is in seconds, may be fractional,
# empty or missing blocks until input arrives.
# also set a readable name for keys (mouse, if mouse mode is on).
# unrecognised CSI sequences are swallowed whole and gives an empty key.
# On timeout or an interrupting trapped signal it returns 0 with _TUI_KEY
# empty, so an empty key is a "tick". Returns 1 only on EOF.
_tui_parse_key() {
  local k seq t fin num rc=0
  local -a opt=()
  [[ -n ${1:-} ]] && opt=(-t "$1")
  _TUI_KEY=
  IFS= read -rsn1 "${opt[@]}" k || rc=$?
  # timed out, or a trapped signal (WINCH) interrupted the read:
  # (succeded but with empty key, a "tick")
  (( rc > 128 )) && return 0
  (( rc )) && return 1 # EOF
  case $k in
    $'\e')
      # We may have a lone Esc key press or a start of a key sequence,
      # read up to two more bytes with short timeout so we can be sure.
      IFS= read -rsn2 -t 0.01 seq
      case $seq in
        # Plain arrows, home and end. "[X" is the normal cursor mode, "OX" is
        # application mode (SS3), which some terminals and tmux use.
        '[A'|OA) k=up ;;
        '[B'|OB) k=down ;;
        '[C'|OC) k=right ;;
        '[D'|OD) k=left ;;
        '[H'|OH) k=home ;;
        '[F'|OF) k=end ;;
        # ESC [ followed by a digit, a longer sequence, e.g. \e[[5~ (pgup),
        # '\e[[1;5C' (ctrl-right) or '\e[[48;rows;colst' (resize report).
        '['[0-9])
          k=
          seq=${seq:1}
          # Read the rest, one byte at a time, up to the final byte: a letter or ~.
          while IFS= read -rsn1 -t 0.01 t; do
            seq+=$t
            [[ $t == [[:alpha:]~] ]] && break
          done
          # fin: the final byte. num: the leading number, i.e. everything before the
          # first non-digit (5 for "5~", 1 for "1;5C").
          fin=${seq: -1} num=${seq%%[!0-9]*}
          if [[ $fin == '~' ]]; then
            case $num in
              1|7) k=home ;;
              2)   k=insert ;;
              3)   k=delete ;;
              4|8) k=end ;;
              5)   k=pgup ;;
              6)   k=pgdn ;;
            esac
          else
            # Arrows with modifiers, e.g. ESC [ 1 ; 5 C. The modifier is discarded,
            # so ctrl-right arrives as plain right.
            case $fin in
              A) k=up ;;
              B) k=down ;;
              C) k=right ;;
              D) k=left ;;
              H) k=home ;;
              F) k=end ;;
            esac
          fi ;;
        '') k=esc ;;
        # NOTE: anything else (e.g. ESC [ Z, alt+key) matches no arm and leaves k as a
        # raw ESC character.
      esac
      ;;
    # read -n1 returns an empty string for the delimiter (newline), so empty is Enter.
    '')  k=enter ;;
    ' ') k=space ;;
  esac
  _TUI_KEY=$k
}
