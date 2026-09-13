' cursortest.bas - does the mouse cursor corrupt the pop-up keypads?
'
' DrawControl() and the OSK draw paths now bracket their redraw with
' CursorSuspend so CursorRefresh cannot save half-drawn pixels as the
' cursor background.  DrawKeyboard() (TEXTBOX / NUMBERBOX) and
' DrawFmtBox() (FORMATBOX) still only call CursorHide(), so they may
' show the same fault.
'
' HOW TO USE
'   1. Run it.  A cursor appears and follows the mouse.
'   2. Touch/click a box to open its pop-up keypad.
'   3. On a keypad key: PRESS the left button, MOVE the mouse several
'      cursor-widths while still held, THEN release.
'   4. Look for a cursor-sized block of wrong pixels left on the key -
'      a thin white line for a small move, a full rectangle for a big
'      one.  That is the bug.  A clean key means the path is safe.
'   5. Repeat on all three boxes.  Compare with a touch panel if you
'      have one: touch must never corrupt, because there is no cursor.
'
' The BUTTON is the control - already fixed - so it is the reference:
' drag-release on it should stay clean.

' Needs OPTION GUI CONTROLS 8 (or more) set once at the prompt - it
' reboots.  Without it the first GUI command stops with "GUI controls
' not enabled".  Needs a version with USB (or PS2) mouse support.

OPTION EXPLICIT
OPTION DEFAULT NONE

CLS
GUI CURSOR ON                       ' draw the pointer
GUI CURSOR LINK MOUSE               ' and make it follow the mouse

Text 5, 5, "Press a keypad key, MOVE the mouse, then release"
Text 5, 25, "Looking for a cursor-sized block left behind"

GUI CAPTION   #1, "Text",   10,  60
GUI TEXTBOX   #2,           10,  80, 200, 40, RGB(WHITE), RGB(BLUE)

GUI CAPTION   #3, "Number", 10, 135
GUI NUMBERBOX #4,           10, 155, 200, 40, RGB(WHITE), RGB(BLUE)

GUI CAPTION   #5, "Date",   10, 210
GUI FORMATBOX #6, DATE1,    10, 230, 200, 40, RGB(WHITE), RGB(BLUE)

' Reference control: already bracketed, should stay clean under the
' same press-move-release.
GUI BUTTON    #7, "Reference", 240, 80, 150, 40, RGB(WHITE), RGB(GREEN)

Do
  Pause 50
Loop
