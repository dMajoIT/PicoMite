' =====================================================================
'  savetest fixture: the program SaveProgramToFlash has to get right
'
'  Pass 1 of SaveProgramToFlash tokenises the BASIC text.  Passes 2 and 3
'  then scan back over what pass 1 wrote, looking for CSUB and DefineFont
'  blocks: pass 2 measures each blob so its size word can be back-filled,
'  pass 3 rewinds the flash pointer and writes them again with the sizes
'  known.  Ordinary BASIC never exercises any of that, so this fixture
'  carries one of each - and checks the answers, because a mis-sized or
'  mis-placed blob gives the wrong number rather than a clean failure.
'
'  Both scan bases in passes 2 and 3 are hardwired to flash_progmemory,
'  which is what has to change before the writer can target the library
'  region.  This fixture is the characterisation test for that change:
'  run it before and after and every figure must be identical.
' =====================================================================

PRINT "--- savetest ---"

' 1. ordinary BASIC, to prove pass 1 is untouched
DIM INTEGER i, t
t = 0
FOR i = 1 TO 100 : t = t + i * i : NEXT i
PRINT "basic    "; t

' 2. the font, which proves the DefineFont branch of passes 2 and 3
FONT 8
PRINT "fontw    "; MM.INFO(FONTWIDTH)
PRINT "fonth    "; MM.INFO(FONTHEIGHT)
FONT 1

' 3. the CSUB, which proves the size word was back-filled correctly
DIM INTEGER a, b, s, m
a = 1234 : b = 5678
CHECKSUM a, b, s, m
PRINT "csub1    "; s; " "; m
a = -99 : b = 7
CHECKSUM a, b, s, m
PRINT "csub2    "; s; " "; m

PRINT "--- end ---"
END

CSUB CHECKSUM
	00000000
	'checksum_csub
	6804B5F0 68086845 B0896849 95059404 414D1824 41491800 60556014 25002400 
	91079006 2100469C 95039402 97019600 0EC24814 4313014B 01439301 9A009300 
	1A129B01 9C04418B 19129D05 9C06416B 19129D07 9D02416B 24009E03 41731952 
	18ED2301 00524166 95022100 08509603 D1DE2D10 2B009B03 4663D1DB 60596018 
	BDF0B009 00001234 
End CSUB

DefineFont #8
	08200808 00000000 00000000 18181818 00180018 00246666 00000000 247E2424 
	0024247E 3C583E18 00187C1A 10086462 00864620 76386C38 0076CCDC 00301818 
	00000000 
End DefineFont
