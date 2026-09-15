# Exile world census

Evidence behind `docs/Exile_Port_Design_Review.html`: a console harness that
walks all 65,536 squares of Exile's world through Jon Saffron's
ExileWorldGenerator (a C# transcription of the 6502 landscape generator,
palette logic and sprite tables) and reports what a PicoMite port has to
store and draw.

The generator is MIT-licensed but is not vendored here. To reproduce:

    git clone --depth 1 https://github.com/JonSaffron/ExileWorldGenerator.git ewg
    mkdir build && cd build
    cp ../ewg/{CalculateBackground,CalculateBackgroundObjectData,CalculatePalette,InstructionsFor6502,Palette,PaletteData,GetPaletteResult,GeneratedBackground,BackgroundOverride,BackgroundObjectType,GameColour,WaterLevelType}.cs .
    sed 's/return HashCode.Combine(this.X, this.Y);/return this.X | (this.Y << 8);/' ../ewg/WorldSquare.cs > WorldSquare.cs
    sed -e 's/private static int GetPixelColour/internal static int GetPixelColour/' \
        -e 's/private static readonly Dictionary<byte, Rectangle> SpritePositions/internal static readonly Dictionary<byte, Rectangle> SpritePositions/' \
        -e 's/private static readonly byte\[\] SpriteHeightLookup/internal static readonly byte[] SpriteHeightLookup/' \
        -e 's/private static readonly byte\[\] SpriteWidthLookup/internal static readonly byte[] SpriteWidthLookup/' \
        ../ewg/SpriteBuilder.cs > SpriteBuilder.cs
    cp ../Program.cs .

Compile against the .NET Framework (no SDK needed; the Roslyn csc that ships
with Visual Studio works):

    FW="C:/Windows/Microsoft.NET/Framework64/v4.0.30319"
    csc -nologo -nowarn:8632,8600,8602,8603,8604,8625 -out:harness.exe \
        -r:"$FW/mscorlib.dll" -r:"$FW/System.dll" -r:"$FW/System.Core.dll" \
        -r:"$FW/System.Drawing.dll" -r:"$FW/System.ValueTuple.dll" *.cs
    ./harness.exe 8a 4a 30 12        # x, y (hex square), width, height in squares

Output (2026-09-14):

    mapped 1024 overrides 2594 tertiary-events 439 triples 436 sprite-variants 413
    variants: blank 15  all-priority 392  all-plain 3  mixed 3
              -> tileset A (under) 6, tileset B (over) 395, total 401
    pixels: priority 100773  plain 1611
    distinct tile palette bytes: 34

`region.png` is the requested window rendered through the generator's own
sprite builder and scaled 2:1 for square pixels (`landing_site.png` here is
30 x 12 squares from (&8a, &4a)); `world_class.bin` is one byte per square
(0 open, 1 rock, 2 spaceship, 3 other) from which `world_map.png` was drawn.
