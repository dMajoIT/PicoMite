using System;
using System.IO;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Text;

namespace ExileWorldGenerator
{
    static class Harness
    {
        struct Sq { public byte b, o, pb; }
        static void Main(string[] args)
        {
            var sq = new Sq[65536];
            var variants = new Dictionary<int, int>();   // (sprite,fh,fv,yoff,pal) -> count
            var triples = new HashSet<int>();
            int mapped = 0, overrides = 0, events = 0;
            for (int y = 0; y < 256; y++)
            for (int x = 0; x < 256; x++)
            {
                var g = CalculateBackground.GetBackground((byte)x, (byte)y);
                if (g.IsMappedData) mapped++;
                var o = CalculateBackgroundObjectData.GetBackgroundObjectData(g.Result, (byte)x);
                byte b = g.Background, r = g.Orientation;
                if (o != null) { b = o.Background; r = o.Orientation; overrides++; if (o is BackgroundEvent) events++; }
                var p = CalculatePalette.GetPalette(b, r, (byte)x, (byte)y);
                byte fb = p.Background ?? b, fo = p.Orientation ?? r, pb = p.PaletteData.Palette.PaletteByte;
                sq[y * 256 + x] = new Sq { b = fb, o = fo, pb = pb };
                triples.Add((fb << 16) | (fo << 8) | pb);
                int sprite = SpriteBuilder.BackgroundSpriteLookup[fb] & 0x7f;
                bool fh = SpriteBuilder.FlipSpriteHorizontally[sprite] ^ ((fo & 0x80) != 0);
                bool fv = SpriteBuilder.FlipSpriteVertically[sprite] ^ ((fo & 0x40) != 0);
                int yoff = SpriteBuilder.BackgroundYOffsetLookup[fb] & 0xf0;
                int key = (sprite << 24) | ((fh ? 1 : 0) << 23) | ((fv ? 1 : 0) << 22) | (yoff << 8) | pb;
                int c; variants.TryGetValue(key, out c); variants[key] = c + 1;
            }
            Console.WriteLine("mapped {0} overrides {1} tertiary-events {2} triples {3} sprite-variants {4}", mapped, overrides, events, triples.Count, variants.Count);

            // classify each sprite variant by pixel group: priority (GameColour >= 8) vs plain (1..7) vs zero
            int allPri = 0, allPlain = 0, mixed = 0, blank = 0; long priPx = 0, plainPx = 0;
            int inA = 0, inB = 0;
            foreach (var kv in variants)
            {
                int key = kv.Key; int sprite = key >> 24; int pb = key & 0xff;
                var pal = Palette.FromByte((byte)pb);
                var rect = SpriteBuilder.SpritePositions[(byte)sprite];
                int pri = 0, plain = 0;
                for (int yy = 0; yy < rect.Height; yy++)
                for (int xx = 0; xx < rect.Width; xx++)
                {
                    int li = SpriteBuilder.GetPixelColour(rect.X + xx, rect.Y + yy);
                    if (li == 0) continue;
                    GameColour gc = li == 1 ? pal.Colour1 : li == 2 ? pal.Colour2 : pal.PrimaryColour;
                    if ((int)gc >= 8) pri++; else plain++;
                }
                priPx += pri; plainPx += plain;
                if (pri == 0 && plain == 0) blank++;
                else if (plain == 0) allPri++;
                else if (pri == 0) allPlain++;
                else mixed++;
                if (plain > 0) inA++;
                if (pri > 0) inB++;
            }
            Console.WriteLine("variants: blank {0}  all-priority {1}  all-plain {2}  mixed {3}   -> tileset A (under) {4}, tileset B (over) {5}, total {6}", blank, allPri, allPlain, mixed, inA, inB, inA + inB);
            Console.WriteLine("pixels: priority {0}  plain {1}", priPx, plainPx);

            // distinct palette bytes and the colours they use
            var pals = new HashSet<int>(); foreach (var k in triples) pals.Add(k & 0xff);
            Console.WriteLine("distinct tile palette bytes: {0}", pals.Count);

            // render a region: args x0 y0 w h (tiles)
            int rx = args.Length > 0 ? Convert.ToInt32(args[0], 16) : 0x8c, ry = args.Length > 1 ? Convert.ToInt32(args[1], 16) : 0x36;
            int rw = args.Length > 2 ? int.Parse(args[2]) : 32, rh = args.Length > 3 ? int.Parse(args[3]) : 16;
            var bmp = new Bitmap(rw * 16, rh * 32);
            using (var gfx = Graphics.FromImage(bmp)) gfx.Clear(Color.Black);
            for (int ty = 0; ty < rh; ty++)
            for (int tx = 0; tx < rw; tx++)
            {
                var s = sq[((ry + ty) & 0xff) * 256 + ((rx + tx) & 0xff)];
                var sb = SpriteBuilder.Start(WaterLevelType.AboveWater).AddBackgroundSprite(s.b, s.o, Palette.FromByte(s.pb));
                var fld = typeof(SpriteBuilder).GetField("_sprite", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
                var tile = (Bitmap)fld.GetValue(sb);
                using (var gfx = Graphics.FromImage(bmp)) gfx.DrawImageUnscaled(tile, tx * 16, ty * 32);
            }
            // scale 2x horizontally for square pixels
            var outb = new Bitmap(bmp.Width * 2, bmp.Height);
            using (var gfx = Graphics.FromImage(outb)) { gfx.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor; gfx.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.Half; gfx.DrawImage(bmp, 0, 0, outb.Width, outb.Height); }
            outb.Save("region.png", ImageFormat.Png);
            Console.WriteLine("region.png {0}x{1} from tile ({2:x2},{3:x2})", outb.Width, outb.Height, rx, ry);

            // full-world class map for the document: 0 space, 1 rock, 2 spaceship/mapped, 3 other
            var cls = new byte[65536];
            for (int i = 0; i < 65536; i++)
            {
                byte b = sq[i].b;
                bool rock = b == 0x12 || b == 0x13 || b == 0x1e || b == 0x1f || b == 0x20 || (b >= 0x23 && b <= 0x25) || (b >= 0x2a && b <= 0x31) || b == 0x39 || b == 0x3b || b == 0x10 || b == 0x21;
                bool ship = (b >= 0x14 && b <= 0x18) || b == 0x1c || b == 0x1d || (b >= 0x26 && b <= 0x29) || b == 0x32 || (b >= 0x33 && b <= 0x38) || b == 0x3d || b == 0x3e || b == 0x3f || b == 0x0c;
                cls[i] = (byte)(b == 0x19 ? 0 : rock ? 1 : ship ? 2 : 3);
            }
            File.WriteAllBytes("world_class.bin", cls);
        }
    }
}
