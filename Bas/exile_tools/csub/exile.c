/* exile.c - Exile's object update as a PicoMite CSUB: one call, one tick, all sixteen slots.
 *
 * update_objects (&1a0b) transcribed from the level7 listing at the 8-bit
 * level: for every occupied slot, update_object with its integration, water
 * and buoyancy, the collision pass against the other objects and against
 * the tiles, support and wedging, removal by distance, the teleport
 * countdown, the surface wind, the per-type update routine, the held
 * object, explosions, demotion, and the write-back.  The player's routine
 * is the one validated in exilephys.c; the others come one family at a time.
 *
 *     ExileTick obj(), game(), world(), tbl(), feed()
 *
 * obj()   the sixteen slots as the game keeps them, one table per field
 *         (index = field * 16 + slot; exilestate2.h names the fields)
 * game()  the game's variables (exilestate2.h names them)
 * world() the 65,536 tile bytes of world_types.bin
 * tbl()   the packed tables of tables.bin
 * feed()  in feed mode, the record of what the real game saw each tick: the
 *         keys, the water level, the screen position, and every random
 *         number it drew, keyed by the address that drew it; the kernel
 *         asks for the ones it models and skips the rest.  In game mode the
 *         kernel draws its own.
 *
 * A CSUB has no writable static data, so everything lives in the argument
 * arrays or on the stack.  32-bit integer arithmetic only.
 */
#include "exilestate2.h"

#ifdef _MSC_VER
#define EXPORT __declspec(dllexport)      /* host_test.py builds this as a DLL to check it on the PC */
#include <stdio.h>
#else
#define EXPORT
#endif

typedef unsigned char u8;

/* slot table access */
#define OT(f, s) ((int)obj[(f) * NSLOT + (s)])
#define OS(f, s, v) (obj[(f) * NSLOT + (s)] = (v))

/* behind the 64 KB of tile bytes the world array carries what the game's tile
   lookup (get_tile_and_check_for_tertiary_objects) leaves for each square:
   the tertiary object's data-byte offset (&bd, 0 for none) and type-byte offset (&be) */
#define TERT_DATA(g, x, y) ((g)->world[65536 + ((y) << 8) + (x)])
#define FROM_MAP(g, x, y)  (((g)->world[196608 + ((((y) << 8) + (x)) >> 3)] >> (((x)) & 7)) & 1 ? 0x80 : 0)
#define TERT_TYPE(g, x, y) ((g)->world[131072 + ((y) << 8) + (x)])

/* sites the kernel asks the feed for */
#define SITE_DAMAGE_IMMOB 0x24AD      /* BIT &da in damage_object */
#define SITE_RELIABILITY 0x2DA0       /* CMP &da in check_reliability */
#define SITE_DRAIN_CARRY 0x2D79       /* the carry into reduce_energy_of_weapon_X */
#define SITE_VISIBILITY 0x1CF6        /* JSR rnd for the red-mushroom visibility */
#define SITE_TOUCH_THIS 0x2B11        /* JSR rnd: note this object touching the other */
#define SITE_TOUCH_OTHER 0x2B1A       /* JSR rnd: note the other touching this */
#define SITE_SIGNS       0x22FE   /* the sign register on entry to the relative-position routine */
#define SITE_PLOTW       0x39B2   /* the sprite width the last plot left, read by the look-ahead space check */
#define SITE_TILE        0x1787   /* a tile's routine called: x | y << 8 | mode << 16 */

struct G {
    long long *obj, *game, *feed, *part;
    int nPart;                    /* &1e58: the last particle's index, -1 for none */
    int jetFlags;                 /* &0217: the one table byte the game rewrites as it runs */
    int nSnd;                     /* how many sounds started this tick, for the drawing to play */
    const u8 *world, *tab;
    int frm, angle, facing, immob, tImmob, rotVel, lying, aim, aimVel, aimFlip;
    int jetOk, inWater, tbColl, surr, wedged, signs, windSign, relTX, relTY, walkSpd, maxAcc0;
    int fireCool, waterTile, boosterCol, suitCol, cross[3];
    int weapon, fired, blaster, pockUsed, telRem, telNext, scrollX, scrollY;   /* &084d, &29d7, &36, &0847, &0822, &0821, &14c8, &14ca */
    int wLo[6], wHi[6], pocket[5], telX[5], telY[5];                           /* &084e, &0854, &0848, &0823, &0828 */
    int eventsOn, promoteOn, wlDes[4];                     /* whether update_events runs; &0836 the waterlines' desired y */
    /* the screen: &c7-&ce the origin, the fractions it is scrolling by and their
       signs, &cf/&d1 the sections to scroll, &161c/&161e the scrolling velocity,
       &14cd whether the scroll has uncovered new tiles */
    int orgF[3], org[3], frac[3], sgn[3], secs[3], sVel[3], newTiles;
    int secMode, secNext, secShuf, secDist;     /* &0b76, &0b73, &0b74, &0b77: promotion */
    int fedScr[10];                             /* what the trace says the screen did, to check against */
    int feedMode, feedPos, wl[8], fault, faultArg, rnd[4];
    int held, demat, heldColl, scr[10], redMush, preAng, preMag, retrieve, viewpoint, feedEnd;
    int cYF, cYS, anyB, collTop, obs[4];        /* &18, &1a, &19, &1a again, &77-&7a: shared zero page */
    int tgt[4], x17, y17, wlBlock, doorSup, mode, routeBest; /* the target pseudo-slot, the odd 18th bytes, &3598, &3599, &2d, &3ce4 */
    int expTimer, flood, blueMush, immunity;    /* &081d, &081e, &081b, &0815 */
    int fireImm;                                /* &0814: the fire immunity device */
    int doorTimer;                              /* &0819: the self-closing doors' timer */
    int quake, shipMoving, radImm, whistle1, whistle2, chatterRes, eastOf76;   /* &081f, &19ab, &0818, &27, &29d8, &081c, &19aa */
    int clawAvail[4], clawTel[4];               /* &083f, &0843: the clawed robots */
    int accPower, accSign, accDmg, lastTile;    /* &35, &29, &28: the explosion acceleration; &08: the tile last looked at */
    int lastPlotW;                              /* &4b: the width the last sprite plot left behind */
    int gifts[5];                               /* &083a: what the imps have left to give */
    int kh[39];
    int collected[19];
    int tert[235];
    int npcW0;
};

struct P {
    struct G *g;
    int slot, type, target, tflags, tx, ty, tdataOff, data, isStatic, removal, visibility;
    int npcType, stimuli, rawW, cenC;           /* &22, &21, &4b (the sprite width byte), the carry the centre leaves */
    int nearestDist;                            /* &3c28: how far the object find_or_count found */
    int pvel[3];                                /* &44, &46: the velocities the update started with */
    int ps[3], pf[3], vel[3], acc[3], siz[3], mxp[3], mxf[3], vec[3], qps[3], qpf[3];
    int flags, prevFlags, spr, prevSpr, pal, energy, state, timer, touch, weight, typeFlags, palDefault;
    int fc, fc16, aimAccT, objCY, objCX, child, tileAng, upright;
    int wlFrac, wlRow, tileX, tileY, tYoff, tFlip, tAddr, bYoff, bFlip, bAddr, topR, botR, waterline, mag;
    int xFlip, yFlip, xFlipP, cy, ov, rc, mxCarry, vecA, vel0, vel2;
    int heldX[3], heldF[3];       /* where a held object was put (&0a-&0d) */
    int cen[3], cenf[3];          /* this object's centre (&87-&8e) */
    int angleB5, relLog, distF, dist, tileF[3], lastEnergy, count, findsCarry;
};

/* ---- 8-bit helpers ------------------------------------------------------ */

static inline int neg8(int a) { return (-a) & 255; }
static inline int inv_neg(int a) { return (a & 128) ? neg8(a) : a; }

static int add8(struct P *p, int a, int b, int c)
{
    int t = a + b + c, r = t & 255;
    p->cy = t >> 8;
    p->ov = ((~(a ^ b)) & (a ^ r) & 128) != 0;
    return r;
}

static int sub8(struct P *p, int a, int b, int c)
{
    int t = a - b - 1 + c, r = t & 255;
    p->cy = t >= 0;
    p->ov = ((a ^ b) & (a ^ r) & 128) != 0;
    return r;
}

static int asr(struct P *p, int a)          /* CMP #&80 ; ROR A */
{
    p->cy = a & 1;
    return (a & 128) | (a >> 1);
}

static int prevent_overflow(struct P *p, int a) { return p->ov ? (0x7F + p->cy) & 255 : a; }

static int seven_eighths(int a)
{
    int q = inv_neg(a), e;
    q = (q + 7) & 255;
    e = q >> 3;
    if (a & 128) e = neg8(e);
    return (a - e) & 255;
}

static int keep_range(int a, int rng)
{
    if (inv_neg(a) < rng) return a;
    return (a & 128) ? neg8(rng) : rng;
}

static int halve_toward_zero(struct P *p, int v)
{
    int a = asr(p, v), c = p->cy;
    if (a & 128) a = (a + c) & 255;
    return a;
}

static inline int jumping(struct P *p) { return (p->state & 15) >= 10; }
static inline int get_sign(int a) { return (a & 128) ? 0xFF : 1; }

/* the game's generator, as rnd (&2587) with A = 0 on entry: the value in
   bits 0-7 and the carry it leaves in bit 8 (some callers add that carry) */
static int rnd_advance(struct G *g)
{
    int a = 0, t;
    a = (a + g->rnd[3]) & 255;
    a = (a + g->rnd[0]) & 255; g->rnd[0] = a;
    a = (a + g->rnd[2]) & 255; g->rnd[2] = a;
    a = (a + g->rnd[1]) & 255; g->rnd[1] = a;
    t = a + g->rnd[3]; a = t & 255; g->rnd[3] = a;
    return a | ((t >> 8) << 8);
}

static void fault(struct G *g, int code, int arg)
{
    if (!g->fault) { g->fault = code; g->faultArg = arg; }
}

/* the random number the game drew at `site`, from the feed (skipping the
   sites the kernel does not model) or from the kernel's own generator */
static int read_site(struct G *g, int site)
{
    if (g->feedMode) {
        const int *f = (const int *)g->feed;
        while (g->feedPos < g->feedEnd) {
            int s = f[g->feedPos], v = f[g->feedPos + 1];
            g->feedPos += 2;
            if (s == site) return v;
        }
        fault(g, 1, site);
        return 0;
    }
    if (site == SITE_DRAIN_CARRY) return 0;
    if (site == SITE_DAMAGE_IMMOB || site == SITE_RELIABILITY) return g->rnd[1];
    if (site >= 0x10000) return g->rnd[site & 3];        /* a direct read of rnd_state + n */
    return rnd_advance(g);
}

/* the next entry of the feed without taking it: the site, or -1 at the end */
static int peek_site(struct G *g, int *value)
{
    const int *f = (const int *)g->feed;
    if (!g->feedMode || g->feedPos >= g->feedEnd) return -1;
    *value = f[g->feedPos + 1];
    return f[g->feedPos];
}

/* a direct read of rnd_state + n at `site` (the feed keys it by the instruction) */
#define RND_STATE_READ(n) (0x10000 | (n))
static int read_rnd_byte(struct G *g, int site, int n)
{
    if (g->feedMode) return read_site(g, site) & 255;
    return g->rnd[n];
}

/* the object tables as the 6502 addresses them, including the bytes past the
   sixteen slots that some routines reach: the target pseudo-slot at index 16
   and whatever lies after each table */
static const int OBJ_BASE[18] = {0x0860, 0x0870, 0x0880, 0x0891, 0x08A3, 0x08B4, 0x08C6, 0x08D6, 0x08E6,
                                 0x08F6, 0x0906, 0x0916, 0x0926, 0x0936, 0x0946, 0x0956, 0x0966, 0x0976};

static int obj_at(struct G *g, int addr)
{
    long long *obj = g->obj;
    int f;
    if (addr == 0x0890) return g->tgt[1];
    if (addr == 0x08A1) return g->tgt[0];
    if (addr == 0x08A2) return g->x17;
    if (addr == 0x08B3) return g->tgt[3];
    if (addr == 0x08C4) return g->tgt[2];
    if (addr == 0x08C5) return g->y17;
    if (addr >= 0x0986 && addr < 0x0986 + 235) return g->tert[addr - 0x0986];
    for (f = 0; f < 18; f++)
        if (addr >= OBJ_BASE[f] && addr < OBJ_BASE[f] + 16) return OT(f, addr - OBJ_BASE[f]);
    fault(g, 12, addr);
    return 0;
}

static void obj_set(struct G *g, int addr, int v)
{
    long long *obj = g->obj;
    int f;
    if (addr == 0x08A1) { g->tgt[0] = v; return; }
    if (addr == 0x0890) { g->tgt[1] = v; return; }
    if (addr == 0x08C4) { g->tgt[2] = v; return; }
    if (addr == 0x08B3) { g->tgt[3] = v; return; }
    for (f = 0; f < 18; f++)
        if (addr >= OBJ_BASE[f] && addr < OBJ_BASE[f] + 16) { OS(f, addr - OBJ_BASE[f], v); return; }
    fault(g, 13, addr);
}

/* ---- positions and extents ----------------------------------------------- */

static void add_to_pos(struct P *p, int xi, int a, int n)
{
    int t;
    if (n) p->ps[xi] = (p->ps[xi] - 1) & 255;
    t = a + p->pf[xi];
    p->pf[xi] = t & 255;
    if (t > 255) p->ps[xi] = (p->ps[xi] + 1) & 255;
}

static void maxima(struct P *p)
{
    struct G *g = p->g;
    int xi, t;
    p->mxCarry = g->cross[0] & 1;
    for (xi = 2; xi >= 0; xi -= 2) {
        t = p->siz[xi] + p->pf[xi];
        p->mxf[xi] = t & 255;
        p->mxp[xi] = (p->ps[xi] + (t >> 8)) & 255;
        g->cross[xi] = ((t >> 8) << 7) | (g->cross[xi] >> 1);
    }
}

static void get_waterline(struct P *p, int x)
{
    struct G *g = p->g;
    int xi = 4;
    do { xi--; } while (x < g->tab[T_WLX + xi]);
    p->wlFrac = g->wl[xi]; p->wlRow = g->wl[4 + xi];
    if (p->wlRow * 256 + p->wlFrac > g->wl[5] * 256 + g->wl[1]) { p->wlFrac = g->wl[1]; p->wlRow = g->wl[5]; }
}

static void get_this_object_centre(struct P *p)
{
    int xi;
    for (xi = 2; xi >= 0; xi -= 2) {
        int a = p->siz[xi] >> 1, c = p->siz[xi] & 1, t = a + p->pf[xi] + c, s = p->ps[xi] + (t >> 8);
        p->cenf[xi] = t & 255;
        p->cen[xi] = s & 255;
        p->cenC = s >> 8;
    }
}

/* ---- tiles ----------------------------------------------------------------- */

static void weighted_accel(struct P *p, int desired, int yy, int xi, int maxacc);

static int angle_from_vec(struct P *p);
static int read_rnd_byte(struct G *g, int site, int n);

static void vec_from_mag_angle(struct P *p, int mag, int ang);   /* &2357, defined below */
static void get_waterline(struct P *p, int x);

/* ---- the particle system (&218e add_particles, &207e update_particles) ---------------------

   Thirty-two particles in their own array, eight words each, laid out as the
   game lays them out: the two velocities, the two position fractions, the two
   squares, the time to live, and the colour with its flags.  A particle type
   is an offset into an eleven-byte record, so the type numbers below are the
   game's own.  The base position is &87-&8e, which this object's centre also
   uses, so it is already in the struct. */
#define PT(f, i)      ((int)g->part[(i) * 8 + (f)])
#define PTS(f, i, v)  (g->part[(i) * 8 + (f)] = (v))
enum { P_VX, P_VY, P_XF, P_YF, P_X, P_Y, P_TTL, P_CF };
enum { PT_TTLR, PT_TTL, PT_SPDR, PT_SPD, PT_CF, PT_CFR, PT_FLAGS, PT_XR, PT_YR, PT_VXR, PT_VYR };

/* update_particle (&20e6): carry a particle along by its velocity.  The game
   does this once as the particle is made and again on every tick after. */
static void move_particle(struct P *p, int i)
{
    struct G *g = p->g;
    int j, a, c, vel;
    for (j = 0; j < 2; j++) {
        vel = PT(j ? P_VY : P_VX, i);
        a = add8(p, vel, PT(j ? P_YF : P_XF, i), 0);
        PTS(j ? P_YF : P_XF, i, a);
        c = p->cy;
        a = PT(j ? P_Y : P_X, i);
        if (c) a = (a + 1) & 255;
        if (vel & 128) a = (a - 1) & 255;
        PTS(j ? P_Y : P_X, i, a);
    }
}

/* find_free_particle_slot (&215d): the next one, or a random one to replace
   once all thirty-two are in use */
/* play_sound (&13fa): the kernel does not make a noise, it says which of the
   game's forty-eight sounds started this tick and leaves the rest to the
   program that draws.  Nothing here can move a random draw, so a sound can be
   put in wherever the game has one without disturbing the physics. */
static void play_sound(struct G *g, int n)
{
    if (g->nSnd < 8) g->game[G_SND0 + g->nSnd++] = n;
}

static int free_particle(struct G *g)
{
    /* The two draws a particle can make on its own account - which one to
       replace when all thirty-two are in use, and the colour the water turns
       one - are taken from the generator directly rather than from the feed.
       A particle's life depends on what the game's plotting found under it,
       pixel by pixel, which the kernel cannot see; so particle lifetimes are
       close but not exact, and this keeps that from moving any draw the
       physics depends on. */
    if (g->nPart >= 0x1F) return (g->rnd[1] & 0xF8) >> 3;
    g->nPart++;
    return g->nPart;
}

/* add_particles (&218e): n particles of type ty.  cf and cfr are the colour and
   its mask as the caller has them, which for two of the types the game rewrites
   as it runs; the rest of the record is constant and comes from the table. */
static void add_particles_t(struct P *p, int n, int px, int py, int cf, int cfr, int ty)
{
    struct G *g = p->g;
    const u8 *T = g->tab + T_PARTTYPE + ty;
    int a, c, fl, i, xi, r, vel, frac, sq, sgn, who;
    fl = (ty == 0x0B) ? g->jetFlags : T[PT_FLAGS];   /* the jetpack's are chosen per call */
    if (fl & 0x20) {                             /* the base is this object's own corner */
        p->cenf[0] = p->pf[0]; p->cen[0] = p->ps[0];
        p->cenf[2] = p->pf[2]; p->cen[2] = p->ps[2];
    }
    a = (g->scr[0] - px - 2) & 255;
    if (a < 0xF6) return;                        /* off the left or the right of the screen */
    a = (py - g->scr[1] + 1) & 255;
    if (a >= 6) return;                          /* off the top or the bottom */
    if (fl & 0x80) {                             /* they move against this object */
        p->vec[0] = (fl & 0x40) ? p->acc[0] : p->vel[0];
        p->vec[2] = (fl & 0x40) ? p->acc[2] : p->vel[2];
        p->angleB5 = angle_from_vec(p) ^ 0x80;
    }
    r = read_site(g, 0x21D7);                    /* one speed for the whole batch */
    vec_from_mag_angle(p, add8(p, r & T[PT_SPDR], T[PT_SPD], 0), p->angleB5);
    a = (fl << 3) & 255;                         /* the placing bits, three along */
    for (xi = 2; xi >= 0; xi -= 2) {
        int off = 0, flip = xi ? p->yFlip : p->xFlip;
        c = (a >> 7) & 1; a = (a << 1) & 255;
        if (c && (flip & 128)) off = p->siz[xi];
        c = (a >> 7) & 1; a = (a << 1) & 255;
        if (c) off = p->siz[xi] >> 1;
        p->cenf[xi] = add8(p, off, p->cenf[xi], 0);
        p->cen[xi] = add8(p, p->cen[xi], 0, p->cy);
    }
    while (n-- > 0) {
        r = read_rnd_byte(g, 0x220D, 1);
        g->signs = ((r & cfr) ^ cf) & 7;         /* the colour, left in the sign register */
        who = free_particle(g);
        PTS(P_CF, who, (r & cfr) ^ cf);
        r = read_site(g, 0x2220);
        PTS(P_TTL, who, add8(p, r & T[PT_TTLR], T[PT_TTL], 0));
        for (i = 0; i < 2; i++) {                /* x then y, as the loop runs */
            int vr = T[i ? PT_VYR : PT_VXR], pr = T[i ? PT_YR : PT_XR], ax = i ? 2 : 0;
            r = read_site(g, 0x2232);
            sgn = r & 1;
            c = (r >> 1) & 255;
            c &= vr;
            if (sgn) c ^= 255;
            a = add8(p, c, p->vec[ax], sgn);
            vel = prevent_overflow(p, a);
            c = p->cy;
            r = read_rnd_byte(g, 0x2243, 1);
            frac = add8(p, r & pr, p->cenf[ax], c);
            sq = add8(p, p->cen[ax], 0, p->cy);
            PTS(i ? P_VY : P_VX, who, vel);
            PTS(i ? P_YF : P_XF, who, frac);
            PTS(i ? P_Y : P_X, who, sq);
        }
        if (fl & 1) {                            /* and carry this object's own motion */
            for (i = 0; i < 2; i++) {
                a = add8(p, PT(i ? P_VY : P_VX, who), p->vel[i ? 2 : 0], 0);
                PTS(i ? P_VY : P_VX, who, prevent_overflow(p, a));
            }
        }
        move_particle(p, who);                   /* &2267: a new one is carried along at once */
    }
}

/* The game asks the screen whether a particle landed on something solid, by
   reading back the pixel it just plotted.  The screen belongs to the drawing
   here, so this asks the world instead: the tile's obstruction profile gives
   the height of solid ground in each of its eight columns. */
static int particle_in_solid(struct P *p, int x, int xf, int y, int yf)
{
    struct G *g = p->g;
    int v = g->world[(y << 8) + x], t = v & 0x3F, flp = v & 0xC0;
    int yo, h, q, a, addr, prof;
    yo = g->tab[T_YOFF + t];
    if (flp & 0x40) yo = (yo << 4) & 255;
    yo &= 0xF0;
    if (yo) yo |= 0x0F;
    h = flp >> 7; q = (flp << 1) & 255;
    a = ((g->tab[T_PAT + t] << 1) | h) & 255;
    a = ((a << 1) | (q >> 7)) & 0x3F;
    addr = g->tab[T_OBOFF + a];
    prof = g->tab[T_OBPAT + addr + (xf >> 5)];
    if (prof == 0) return 0;
    prof = (prof + yo) & 255;
    return yf >= prof;
}

/* update_particles (&207e): every particle a tick.  The game plots and unplots
   as it goes, and reads back the screen to learn what a particle struck; here
   the screen belongs to the drawing, so a particle ends when it leaves the
   view or its time runs out. */
static void update_particles(struct P *p)
{
    struct G *g = p->g;
    int i, j, a, c, cf, alive, vel;
    if (g->nPart < 0) return;
    get_waterline(p, g->scr[0]);
    for (i = g->nPart; i >= 0; i--) {
        cf = PT(P_CF, i);
        alive = 1;
        if (cf & 0x10) {                         /* it falls, or floats up in water */
            int add = 1;
            if (PT(P_Y, i) > p->wlRow ||
                (PT(P_Y, i) == p->wlRow && PT(P_YF, i) >= p->wlFrac)) {
                add = 0xFD;
                g->signs = (g->rnd[1] & 7) | 6;   /* and turns cyan or white */
            }
            a = add8(p, add, PT(P_VY, i), 0);
            if (!p->ov) PTS(P_VY, i, a);
        }
        if (cf & 8) {                            /* its colour cycles */
            a = ((cf & 0xF7) + 1) & 7;
            PTS(P_CF, i, (cf & 0xF8) | a);
        }
        a = (PT(P_TTL, i) - 1) & 255;
        PTS(P_TTL, i, a);
        if (a == 0) alive = 0;
        if (alive) {
            move_particle(p, i);
            a = (g->scr[0] - PT(P_X, i) - 2) & 255;
            if (a < 0xF6) alive = 0;
            else if (((PT(P_Y, i) - g->scr[1] + 1) & 255) >= 6) alive = 0;
            else if (!(cf & 0x20) &&              /* one that does not survive solid ground */
                     particle_in_solid(p, PT(P_X, i), PT(P_XF, i), PT(P_Y, i), PT(P_YF, i)))
                alive = 0;
        }
        if (!alive) {                            /* close the gap, as the game does */
            for (j = 0; j < 8; j++)
                g->part[i * 8 + j] = g->part[g->nPart * 8 + j];
            g->nPart--;
            if (g->nPart < 0) return;
        }
    }
}

/* set_new_particles_position_from_this_object (&3f7f) then add_particle: one
   particle a quarter of a tile up and left of the object, y worked out first
   with the carry the caller arrives with */
static void particle_from_object(struct P *p, int c, int cf, int cfr, int ty)
{
    int px, py, b;
    b = (p->pf[2] - 0x40 - (1 - c)) < 0;
    py = (p->ps[2] - b) & 255;                   /* y is never 0 here, so this leaves the carry set */
    b = p->pf[0] < 0x40;
    px = (p->ps[0] - b) & 255;
    add_particles_t(p, 1, px, py, cf, cfr, ty);
}

/* add_wind_particle_using_velocities (&3f73): the particle itself belongs to
   the particle system, but making it rolls the shared sign register, reads
   random bytes and, when the particle is made, leaves its colour in the sign
   register (add_particles stores the pixel colour in &99) */
static void wind_particle(struct P *p)
{
    struct G *g = p->g;
    int a, b;
    b = g->signs;
    angle_from_vec(p);
    a = read_rnd_byte(g, 0x3F76, 1) >> 1;
#ifdef HOST_DEBUG
    printf("  wind slot %d: signs %02x -> %02x vec %02x,%02x mag %02x rnd>>1 %02x\n", p->slot, b, g->signs, p->vec[0], p->vec[2], p->mag, a);
    fflush(stdout);
#endif
    if (a >= p->mag) return;                     /* more particles the stronger the wind */
    particle_from_object(p, 0, 0x97, 0x41, 0x6E);
}

/* apply_wind_velocities_from_vector (&3f4f), less the debris an event would make */
static void wind_apply(struct P *p)
{
    struct G *g = p->g;
    int xi, yy;
    for (xi = 2; xi >= 0; xi -= 2) {
        yy = p->weight;
        if (yy < 4) yy++;
        if (p->waterline & 128) yy++;
        if ((g->inWater & 128) && !(g->frm & 0x10)) return;
        weighted_accel(p, p->vec[xi], yy, xi, 0x0C);
    }
    wind_particle(p);
}

/* apply_wind_velocities_from_A (&3f47): the nibbles of a are the y and x velocities */
static void wind_from_a(struct P *p, int a)
{
    p->vec[0] = (a << 4) & 255; p->vec[2] = a;
    wind_apply(p);
}

static int tile_effect(struct P *p, int t, int flp);

/* update_water_tile (&3fa3): the water's own current, or the note that the object is in still water */
static void tile_water(struct P *p, int flp)
{
    struct G *g = p->g;
    int wv = g->tab[T_WATERVEL + (((flp >> 7) << 1) | ((flp >> 6) & 1))];
    if (wv) wind_from_a(p, wv);
    else g->waterTile = 128 | (g->waterTile >> 1);
}

static void set_obs_vars(struct P *p, int which)
{
    struct G *g = p->g;
    int v = g->world[(p->tileY << 8) + p->tileX];
    int t = v & 0x3F, flp = v & 0xC0, yo, h, q, fl, a, addr;
    g->lastTile = t;
    t = tile_effect(p, t, flp);
    yo = g->tab[T_YOFF + t];
    if (flp & 0x40) yo = (yo << 4) & 255;
    yo &= 0xF0;
    if (yo) yo |= 0x0F;
    h = flp >> 7; q = (flp << 1) & 255;
    fl = q ^ g->tab[T_SPRF + t];
    a = ((g->tab[T_PAT + t] << 1) | h) & 255;
    a = ((a << 1) | (q >> 7)) & 0x3F;
    addr = g->tab[T_OBOFF + a];
    if (which == 0) { p->tYoff = yo; p->tFlip = fl; p->tAddr = addr; }
    else { p->bYoff = yo; p->bFlip = fl; p->bAddr = addr; }
}

static inline int pattern(struct P *p, int addr, int s) { return p->g->tab[T_OBPAT + addr + s]; }

static int weight_limit(struct P *p, int a, int c, int v, int yy, int maxacc)
{
    int n, m, times, i, cc = 0;
    if (v) a = (0x7F + c) & 255;
    n = a & 128;
    m = inv_neg(a);
    times = (yy < 128) ? yy + 1 : 1;
    for (i = 0; i < times; i++) { cc = m & 1; m >>= 1; }
    m = ((m << 1) | cc) & 255;
    if (m >= maxacc) m = maxacc;
    return n ? neg8(m) : m;
}

static void weighted_accel(struct P *p, int desired, int yy, int xi, int maxacc)
{
    int a = sub8(p, desired, p->vel[xi], 1), accl;
    accl = weight_limit(p, a, p->cy, p->ov, yy, maxacc);
    p->vel[xi] = add8(p, accl, p->vel[xi], 0);
    p->rc = p->cy;
}

static int check_tb(struct P *p, int yy)
{
    struct G *g = p->g;
    int a, a2 = 0, a3 = 0;
    a = add8(p, pattern(p, p->tAddr, yy), p->tYoff, 0);
    if (p->cy) a = 255;
    a = sub8(p, a, p->topR, 1);
    if (p->cy) { if (a >= p->siz[2]) a = p->siz[2]; a2 = a; }
    a = p->siz[2];
    if (g->cross[2] & 128) {
        a = add8(p, pattern(p, p->bAddr, yy), p->bYoff, 0);
        if (p->cy) a = 255;
        if (a >= p->botR) a = p->botR;
        a3 = a;
        if (!(p->bFlip & 128)) a3 = sub8(p, p->botR, a3, 1);
        a = sub8(p, 0, p->topR, 1);
    }
    if (!(p->tFlip & 128)) a2 = sub8(p, a, a2, 1);
    a = add8(p, a2, a3, 0);
    a = add8(p, a, 6, p->cy);
    a = (p->cy << 7) | (a >> 1);
    a >>= 1;
    a &= 0xFE;
    a = ((a ^ 255) + 1) & 255;
    p->rc = (a == 0);
    return a;
}

static void set_position_from_previous(struct P *p)
{
    p->ps[0] = p->qps[0]; p->ps[2] = p->qps[2]; p->pf[0] = p->qpf[0]; p->pf[2] = p->qpf[2];
}

static void halve_clear(struct P *p)
{
    struct G *g = p->g;
    set_position_from_previous(p);
    p->vel[0] = asr(p, p->vel[0]); p->vel[2] = asr(p, p->vel[2]);
    maxima(p);
    p->rc = p->mxCarry;
    g->cYF = g->cYS = p->g->surr = 255;
    g->obs[0] = g->obs[1] = g->obs[2] = g->obs[3] = 0;
}

static int absc(struct P *p, int v)
{
    struct G *g = p->g;
    int c = v <= 0x7F, a = c ? v : ((v ^ 255) + 1) & 255;
    g->signs = ((g->signs << 1) | c) & 255;
    return a;
}

/* calculate_angle_from_A_and_absolute_vector_y (&22d7): a = |x|, mag holds |y| */
static int angle_from_abs(struct P *p, int a)
{
    struct G *g = p->g;
    int m = p->mag, c = a >= m, ang = 8;
    if (c) { int t = a; a = m; m = t; }
    g->signs = ((g->signs << 1) | c) & 255;
    for (;;) {
        a = (a << 1) & 255;
        if (a >= m) { a = (a - m) & 255; c = 1; } else c = 0;
        ang = (ang << 1) | c;
        if (ang & 256) { ang &= 255; break; }
    }
    p->mag = m;
    return ang ^ g->tab[T_HALFQ + (g->signs & 7)];
}

static int angle_from_vec(struct P *p)
{
    int ay = absc(p, p->vec[2]), ax = absc(p, p->vec[0]);
    p->mag = ay;
    return angle_from_abs(p, ax);
}

static void vec_from_mag_angle(struct P *p, int m, int ang)
{
    int bx = m, q = ang, a = 0, i, bt, c, yv;
    for (i = 0; i < 5; i++) {
        bt = q & 1; q >>= 1; c = 0;
        if (bt) { a = add8(p, a, bx, 0); c = p->cy; }
        a = (c << 7) | (a >> 1);
    }
    bt = q & 1; q >>= 1;
    if (bt) { yv = bx; bx = a; bx = sub8(p, yv, bx, 1); a = yv; }
    bt = q & 1; q >>= 1;
    if (bt) { yv = ((a ^ 255) + 1) & 255; a = bx; bx = yv; }
    bt = q & 1; c = 0;
    if (bt) { yv = ((a ^ 255) + 1) & 255; bx = sub8(p, 0, bx, 1); c = p->cy; a = yv; }
    p->vec[0] = bx; p->vec[2] = a; p->vecA = a; p->rc = c;
}

static void tile_collision(struct P *p)
{
    struct G *g = p->g;
    int a, c, yy, xi, n, angl;
    p->tileAng = angle_from_vec(p);
    a = sub8(p, p->tileAng, 0x60, 1);
    yy = (a & 0xC0) >> 6;
    xi = yy ^ 2;
    a = g->obs[yy];
    if (a < g->obs[xi]) a = g->obs[xi];
    if (a == 0) a = 0xFE;
    a = (a << 2) & 255;
    yy = (yy - 1) & 255;
    xi = (yy & 1) << 1;
    if (xi == 0) { a = add8(p, a, 0x0F, 1); if (p->cy) a = 0xFE; }
    n = (yy < 2) ? 1 : (((yy + 1) & 128) != 0);
    if (!n) a = neg8(a);
    add_to_pos(p, xi, a, n);
    maxima(p);
    p->vec[0] = p->vel[0]; p->vec[2] = p->vel[2];
    g->preAng = angle_from_vec(p); g->preMag = p->mag;
    a = sub8(p, g->preAng, p->tileAng, 1); c = p->cy;
    angl = a;
    if (!(a & 128)) {
        a = sub8(p, a, 0x3F, 1);
        a = asr(p, a); a = asr(p, a); a = asr(p, a); c = p->cy;
        a = add8(p, a, angl, c);
        a ^= 255;
        angl = add8(p, a, p->tileAng, 1);
        a = g->preMag;
        c = a >= 0x20;
        if (c) a = 0x20;
        a = sub8(p, a, 2, c);
        if (!p->cy) a = 0;
        a = seven_eighths(a);
        vec_from_mag_angle(p, a, angl);
        p->vel[2] = p->vecA; p->vel[0] = p->vec[0];
    } else {
        a = sub8(p, a, 0xC0, c);
        a = inv_neg(a);
        if (a >= 0x2A) p->rc = 1;
        else if (g->preMag < 0x40) p->rc = 0;
        else halve_clear(p);
    }
}

static void coll_tiles(struct P *p)
{
    struct G *g = p->g;
    int yy, lft, top = 0, rgt, bot = 0, sections, a, c, topRel, botRel, q, done = 0;
    p->topR = (p->pf[2] & 0xF8) | 4;
    p->botR = (p->mxf[2] & 0xF8) | 4;
    yy = p->pf[0] >> 5;
    lft = check_tb(p, yy);
    sections = p->siz[0] >> 5;
    for (;;) {
        a = sub8(p, p->topR, p->tYoff, 1); topRel = p->cy ? a : 0;
        a = sub8(p, p->botR, p->bYoff, 1); botRel = p->cy ? a : 0;
        for (;;) {
            q = pattern(p, p->tAddr, yy);
            if (((q >= topRel) ^ (p->tFlip >> 7)) == 0) top = (top - 1) & 255;
            q = pattern(p, p->bAddr, yy);
            if (((q >= botRel) ^ (p->bFlip >> 7)) == 0) bot = (bot - 1) & 255;
            sections = (sections - 1) & 255;
            if (sections & 128) { done = 1; break; }
            yy++;
            if (yy < 8) continue;
            p->tileX = (p->tileX + 1) & 255;
            set_obs_vars(p, 1);
            if (g->cross[2] & 128) { p->tileY = (p->tileY - 1) & 255; set_obs_vars(p, 0); }
            else { p->tYoff = p->bYoff; p->tAddr = p->bAddr; p->tFlip = p->bFlip; }
            yy = 0;
            break;
        }
        if (done) break;
    }
    bot = (bot << 3) & 255; top = (top << 3) & 255;
    a = sub8(p, top, bot, 1);
    p->vec[0] = a; p->vec[2] = 0;
    g->cYS = a;
    g->cYF = ((a ^ 255) + 1) & 255;
    c = (bot | top) >= 1;
    g->tbColl = (c << 7) | (g->tbColl >> 1);
    rgt = check_tb(p, yy);
    a = sub8(p, rgt, lft, 1); c = p->cy;
    p->vec[2] = a;
    g->obs[0] = lft; g->obs[1] = top; g->obs[2] = rgt; g->obs[3] = bot;
    if ((a | p->vec[0]) != 0) tile_collision(p);
    else if ((lft | top) == 0) p->rc = c;
    else halve_clear(p);
}

static void coll_water_tiles(struct P *p)
{
    struct G *g = p->g;
    int a, a2, xi, tw, yy, h4, c, c2, old;
    g->surr >>= 1;
    a = sub8(p, p->mxf[2], p->wlFrac, 1); xi = a; c = p->cy;
    a2 = sub8(p, p->mxp[2], p->wlRow, c); c2 = p->cy;
    if (a2 != 0) xi = c2 ? 255 : 0;
    p->waterline = xi;
    p->tileX = p->ps[0]; p->tileY = p->ps[2];
    xi = 0; g->waterTile = 0;
    set_obs_vars(p, 0);
    c = g->waterTile >> 7; g->waterTile = (g->waterTile << 1) & 255;
    if (c) xi = 255;
    if (g->cross[2] & 128) {
        p->tileY = (p->tileY + 1) & 255;
        set_obs_vars(p, 1);
        c = g->waterTile >> 7; g->waterTile = (g->waterTile << 1) & 255;
        if (c) xi |= p->mxf[2];
    } else { p->bYoff = p->tYoff; p->bAddr = p->tAddr; p->bFlip = p->tFlip; }
    if (xi < p->waterline) xi = p->waterline;
    tw = xi;
    yy = p->weight; if (yy == 0) yy = 1;
    h4 = p->siz[2] >> 2;
    xi = 4; a = tw;
    c = a ? 0 : 1;
    old = g->inWater; g->inWater = (c << 7) | (old >> 1); c = old & 1;
    if (!(g->inWater & 128)) {
        for (;;) {
            a = sub8(p, a, h4, c); c = p->cy;
            if (!c) break;
            yy = (yy - 1) & 255;
            if (yy & 128) p->vel[2] = (p->vel[2] - 1) & 255;
            else if (yy == 0) p->vel[2] = (p->vel[2] - 2) & 255;
            if (--xi == 0) break;
        }
        if (g->frm % 4 == 0) { p->vel[0] = seven_eighths(p->vel[0]); p->vel[2] = seven_eighths(p->vel[2]); }
    }
    coll_tiles(p);
}

/* ---- collisions with the other objects (&2a64) ----------------------------------- */

static void transfer(struct P *p, int *x, int *a, int *dir, int wdiff, int wsign)
{
    /* apply_collision_to_objects_velocities: X = this velocity, A = the other's.
       Leaves X = this object's new velocity, A = the other's. */
    int tv = *x, ov = *a, fin[2], tr[2], half, i, v;
    fin[1] = ov; fin[0] = tv;                    /* &a1 = other, &a0 = this */
    v = sub8(p, ov, tv, 1);
    v = (v & 128) | (v >> 1);
    if (p->ov) v ^= 128;
    half = v;
    i = wdiff ? wdiff : 1;
    while (i--) v = (v & 128) | (v >> 1);
    v = (v + (v >> 7)) & 255;                    /* CMP #&80 ; ADC #&00 */
    tr[0] = v;
    tr[1] = sub8(p, v, half, 1);
    for (i = 0; i < 2; i++) {
        int xi = i, aa = tr[xi], carry;
        aa = (aa & 128) | (aa >> 1);
        carry = *dir & 1; *dir >>= 1;
        if (!carry) { aa = add8(p, aa, tr[xi], 0); aa = prevent_overflow(p, aa); }
        if (!(wsign & 128)) {
            aa = neg8(aa);
            xi = (xi == 1) ? 0 : 1;
        }
        /* add_to_final_velocity twice: once by the call, once by falling through */
        fin[xi] = add8(p, aa, fin[xi], 0); fin[xi] = prevent_overflow(p, fin[xi]);
        fin[xi] = add8(p, aa, fin[xi], 0); fin[xi] = prevent_overflow(p, fin[xi]);
    }
    *a = fin[1]; *x = fin[0];
}

static void check_other_objects(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int xp2 = (p->ps[0] + 2) & 255, c1 = (p->ps[0] + 2) >> 8, xm2 = (xp2 - 2 - 1 + c1) & 255;
    int ym2 = (p->ps[2] - 2) & 255, o, c;
    for (o = 0; o < NSLOT; o++) {
        int ox = OT(O_X, o), oy, a, ow, oh, opos, ofrac, xi, tf;
        int plusf[3], plus[3], minusf[3], minus[3], smallest, Y, wd, ws, dir;
        if (ox < xm2 || ox >= xp2) continue;
        oy = OT(O_Y, o);
        a = sub8(p, oy, ym2, 0);
        if (a >= 3) continue;
        if (o == p->slot) continue;
        ow = g->tab[T_SPRW + OT(O_SPRITE, o)];
        oh = g->tab[T_SPRH + OT(O_SPRITE, o)];
        opos = oy; ofrac = OT(O_YF, o);
        for (xi = 2; ; xi -= 2) {
            int r = g->tab[T_ROUND + xi], mk = g->tab[T_MASK + xi], c2, c3, c4, osz = xi ? oh : ow;
            a = ofrac | r;
            a = sub8(p, a, p->mxf[xi], 1); c1 = p->cy;
            a &= mk;
            a = sub8(p, a, r, 0); c2 = p->cy;
            plusf[xi] = a;
            a = sub8(p, opos, 0, c2);
            a = sub8(p, a, p->mxp[xi], c1);
            if (!(a & 128)) goto next;
            plus[xi] = a;
            a = osz | r;
            a = add8(p, a, p->siz[xi], 1); c3 = p->cy;
            a |= r;
            a = add8(p, a, plusf[xi], 1); c4 = p->cy;
            minusf[xi] = a;
            a = add8(p, plus[xi], 0, c4);
            a = add8(p, a, 0, c3);
            if (a & 128) goto next;
            minus[xi] = a;
            if ((a | minusf[xi]) == 0) goto next;
            if (xi == 0) break;
            opos = ox; ofrac = OT(O_XF, o);
        }
        if (o == 0) { if (p->slot == g->held) continue; }
        if (!(g->heldColl & 128)) {
            if (p->slot == 0 && o == g->held) continue;
        }
        a = read_site(g, SITE_TOUCH_THIS) & 255;
        if ((a | p->touch) & 128) p->touch = o;
        a = read_site(g, SITE_TOUCH_OTHER) & 255;
        if ((a | OT(O_TOUCHING, o)) & 128) OS(O_TOUCHING, o, p->slot);
        tf = g->tab[T_OBJFLAGS + OT(O_TYPE, o)];
        if (tf & 128) continue;
        wd = tf & 7;
        if (p->typeFlags & 128) continue;
        a = sub8(p, p->typeFlags & 7, wd, 1); c = p->cy;
        ws = c << 7;                               /* weight_difference_sign: negative if this is heavier */
        if (!(ws & 128)) a = neg8(a);              /* invert_if_positive: makes the difference positive */
        wd = a;
        smallest = 255; Y = 0;
        for (xi = 6; xi >= 0; xi -= 2) {
            int pos = (xi & 4) ? minus[xi & 2] : plus[xi & 2];
            int frac = (xi & 4) ? minusf[xi & 2] : plusf[xi & 2];
            int v = ((pos & 1) << 7) | (frac >> 1);
            if (pos & 128) v = neg8(v);
            if (v < smallest) { smallest = v; Y = xi; }
        }
        xi = Y & 2;
        dir = g->tab[T_DIRFLAGS + xi];
        a = g->tab[T_SOFLAGS + Y];
        p->objCY = a & 0xC0;
        p->objCX = (a << 2) & 255;
        {
            int pos = (Y & 4) ? minus[Y & 2] : plus[Y & 2];
            int frac = (Y & 4) ? minusf[Y & 2] : plusf[Y & 2];
            int n = pos & 128;
            a = (get_sign(pos) << 1) & 255;
            p->vel[xi] = add8(p, a, p->vel[xi], 0);
            add_to_pos(p, xi, frac, n);
        }
        maxima(p);
        {
            int tv = p->vel[0], av = OT(O_VX, o);
            transfer(p, &tv, &av, &dir, wd, ws);
            p->vel[0] = tv; OS(O_VX, o, av);
            tv = p->vel[2]; av = OT(O_VY, o);
            transfer(p, &tv, &av, &dir, wd, ws);
            p->vel[2] = tv; OS(O_VY, o, av);
        }
next:   ;
    }
}

/* ---- damage and the surface wind ---------------------------------------------- */

static void reduce_weapon_energy(struct P *p, int x);   /* &2d79, defined below */
static int check_reliability(struct P *p, int xi);      /* &2d92, defined below */

static int damage_slot(struct P *p, int y, int dmg)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int old, a;
    if (y == 0) {
        int da = read_site(g, SITE_DAMAGE_IMMOB), i, c;
        if (!(da & 128)) {
            g->lying >>= 1;
            if (dmg >= g->immob) g->immob = dmg;
        }
        /* &24bb: the protection suit takes twice the damage out of its own
           energy, and while it is reliable the player takes it plain; without
           it, or when it fails, the damage is multiplied by eight */
        if (!(g->suitCol & 128) || (reduce_weapon_energy(p, 5), reduce_weapon_energy(p, 5),
                                    !check_reliability(p, 5)))
            for (i = 0; i < 3; i++) { c = dmg >> 7; dmg = (dmg << 1) & 255; if (c) dmg = (dmg >> 1) | 128; }
    }
    if (dmg >= 8) OS(O_FLAGS, y, OT(O_FLAGS, y) | 8);
    old = OT(O_ENERGY, y);
    a = sub8(p, old, dmg, 1);
    if (!p->cy) a = 0;
    OS(O_ENERGY, y, a);
    p->lastEnergy = old;
    return a;
}

static int damage_without_destroying(struct P *p, int dmg)
{
    long long *obj = p->g->obj;
    int a = damage_slot(p, p->slot, dmg);
    if (a == 0 && p->lastEnergy != 0) { a = 1; OS(O_ENERGY, p->slot, 1); }
    return a;
}

static void surface_wind(struct P *p)
{
    struct G *g = p->g;
    int a, c, xi = 2, yy;
    p->vec[0] = p->vec[2] = 0;
    a = sub8(p, p->ps[2], 0x4E, 0); c = p->cy;
    for (;;) {
        yy = (p->weight + 1) & 255;
        g->windSign = (c << 7) | (g->windSign >> 1);
        a = inv_neg(a);
        if (a < 0x1E) c = 0;
        else {
            if (a < 0x32) c = 0;
            else { yy = (yy - 1) & 255; if (a < 0x3C) c = 0; else { yy = (yy - 1) & 255; c = 1; } }
            a = sub8(p, a, 8, c);
            a = (a << 1) & 255;
            if (a & 128) { yy = (yy - 2) & 255; a = 0x7F; }
            yy = (yy + 1) & 255;
            if (yy & 128) yy = 0;
            if (g->windSign & 128) a = neg8(a);
            p->vec[xi] = a;
            weighted_accel(p, p->vec[xi], yy, xi, 0x0C);
            c = p->rc;
        }
        a = sub8(p, p->ps[0], 0x9B, c); c = p->cy;
        xi -= 2;
        if (xi != 0) break;
    }
    wind_particle(p);
}

/* ---- the player's actions ----------------------------------------------------- */

static void handle_jumping(struct P *p)
{
    struct G *g = p->g;
    int a, c;
    if ((p->state & 15) >= 5) return;
    a = (g->kh[0x15] & 128) ? 0xF0 : 0xF6;
    a = add8(p, a, p->weight, 0);
    c = a >> 7; a = (a << 1) & 255;
    p->vel[2] = add8(p, a, p->vel[2], c);
    p->upright >>= 1;
}

static void use_booster(struct P *p)
{
    struct G *g = p->g;
    if (!((g->jetOk & g->boosterCol) & 128)) return;
    if (!(p->acc[2] & 128) && p->acc[0] != 0) p->state |= 15;
    p->acc[0] = (p->acc[0] << 1) & 255; p->acc[2] = (p->acc[2] << 1) & 255;
}

/* calculate_angle_of_object_X_to_this_object (&22a0) */
static int angle_of_object_to_this(struct P *p, int o)
{
    struct G *g = p->g;
    int spr = obj_at(g, 0x0870 + o), a, c, t, ocen[3], ocenf[3], rel[3], relf[3], absx, yy, ang;
    get_this_object_centre(p);
    a = g->tab[T_SPRW + spr]; c = a & 1; a >>= 1;
    t = a + obj_at(g, 0x0880 + o) + c; ocenf[0] = t & 255; c = t >> 8;
    t = obj_at(g, 0x0891 + o) + c; ocen[0] = t & 255; c = t >> 8;
    a = g->tab[T_SPRH + spr]; c = a & 1; a >>= 1;
    t = a + obj_at(g, 0x08A3 + o) + c; ocenf[2] = t & 255; c = t >> 8;
    t = obj_at(g, 0x08B4 + o) + c; ocen[2] = t & 255; c = t >> 8;
    /* calculate_normalised_relative_position_of_centres (&22fe), Y = 4 then 2.
       Bit 7 of the sign register here is the borrow of the x pass below, and
       in the original it is whatever the sprite plotting, particle plotting
       and sound code last left in &99 (they use it as scratch), which the
       port does not reproduce: a trace hands the byte over, the game keeps
       the kernel's own roll history */
    if (g->feedMode) {
        int s = read_site(g, SITE_SIGNS);
#ifdef HOST_DEBUG
        if ((s ^ g->signs) & 128) { printf("  signs at &22fe: game %02x kernel %02x" "\n", s, g->signs); fflush(stdout); }
#endif
        g->signs = s;
    }
    absx = 0;
    for (yy = 2; yy >= 0; yy -= 2) {
        int i = yy, cin;
        p->mag = absx;                          /* STA &b7: only meaningful on the second pass */
        a = sub8(p, ocenf[i], p->cenf[i], c); relf[i] = a;
        a = sub8(p, ocen[i], p->cen[i], p->cy); rel[i] = a;
        cin = 1;
        if (a & 128) { a = neg8(a); cin = 0; }
        c = g->signs >> 7;                      /* ROL &99 leaves the bit it pushed out as the carry */
        g->signs = ((g->signs << 1) | cin) & 255;
        absx = a;
    }
    a = (absx | p->mag);
    a = (a << 1) & 255;
    yy = 0;
    do {
        c = rel[0] & 1; rel[0] >>= 1; relf[0] = (c << 7) | (relf[0] >> 1);
        c = rel[2] & 1; rel[2] >>= 1; relf[2] = (c << 7) | (relf[2] >> 1);
        yy++;
        a >>= 1;
    } while (a);
    p->relLog = yy;
    p->mag = inv_neg(relf[2]);
    a = inv_neg(relf[0]);
#ifdef HOST_DEBUG
    printf("  angle_to %d: this %02x.%02x %02x.%02x other %02x.%02x %02x.%02x rel %02x.%02x %02x.%02x |x|=%02x |y|=%02x log %d signs %02x\n",
           o, p->cen[0], p->cenf[0], p->cen[2], p->cenf[2], ocen[0], ocenf[0], ocen[2], ocenf[2], rel[0], relf[0], rel[2], relf[2], a, p->mag, yy, g->signs);
    fflush(stdout);
#endif
    ang = angle_from_abs(p, a);
    p->angleB5 = ang;
    return ang;
}

/* check_object_touching_angle (&3bd5): positive if the touched object is within reach */
static int touching_angle(struct P *p)
{
    int o = p->touch, a;
    if (o & 128) return 0x80;
    a = angle_of_object_to_this(p, o);
    a = add8(p, a, 0x40, 1);
    return a ^ p->xFlip;
}

/* ---- the shared creature machinery ------------------------------------------------- */

static void leave_obstructed(struct G *g) { g->doorSup = 0xFF; g->wlBlock = 0xFF; }

/* use_vector_between_object_centres (&3347): a vector of mag towards object o */
static void use_vector(struct P *p, int o, int mag)
{
    int ang = angle_of_object_to_this(p, o);
    p->distF = p->mag;
    vec_from_mag_angle(p, mag, ang);
}

/* check_for_obstruction_along_vector (&35d5): walk d2c steps of vec from this
   object's centre; 1 if a tile (or the waterline, when armed) is in the way */
static int obstruction_along_vector(struct P *p, int d2c)
{
    struct G *g = p->g;
    int xi, a, c, t, startBelow, rounded, yy;
    for (xi = 2; xi >= 0; xi -= 2) {
        p->dist = xi;
        a = p->siz[xi]; c = a & 1; a >>= 1;
        t = a + p->pf[xi] + c; p->tileF[xi] = t & 255; c = t >> 8;
        t = (p->ps[xi] + c) & 255;
        if (xi) p->tileY = t; else p->tileX = t;
    }
    g->mode = 0x40;
    get_waterline(p, p->tileX);
    c = p->tileF[2] >= p->wlFrac;
    sub8(p, p->tileY, p->wlRow, c);
    startBelow = p->cy;
    set_obs_vars(p, 0);
    for (;;) {
        t = p->tileF[2] + p->vec[2]; p->tileF[2] = t & 255; c = t >> 8;
        rounded = (p->tileF[2] & 0xF8) | 4;
        if (p->vec[2] & 0x40) { if (!c) { p->tileY = (p->tileY - 1) & 255; set_obs_vars(p, 0); } }
        else if (c) { p->tileY = (p->tileY + 1) & 255; set_obs_vars(p, 0); }
        t = p->tileF[0] + p->vec[0]; p->tileF[0] = t & 255; c = t >> 8;
        if (p->vec[0] & 0x40) { if (!c) { p->tileX = (p->tileX - 1) & 255; set_obs_vars(p, 0); } }
        else if (c) { p->tileX = (p->tileX + 1) & 255; set_obs_vars(p, 0); }
        yy = p->tileF[0] >> 5;
        t = pattern(p, p->tAddr, yy) + p->tYoff;
        a = t > 255 ? 255 : t;
        c = a >= rounded;
        if ((((c << 7) | (a >> 1)) ^ p->tFlip) & 128) {
            if (g->wlBlock & 128) {
                c = p->tileF[2] >= p->wlFrac;
                sub8(p, p->tileY, p->wlRow, c);
                if (p->cy != startBelow) { leave_obstructed(g); return 1; }
            }
        } else { leave_obstructed(g); return 1; }
        p->dist = (p->dist + 1) & 255;
        d2c = (d2c - 1) & 255;
        if (d2c == 0) break;
    }
    return 0;
}

/* check_for_obstruction_between_objects (&359c): 1 if no line of sight to
   object o within maxd (in &20 fractions); leaves the distance in p->dist */
static int obstruction_between(struct P *p, int o, int maxd)
{
    struct G *g = p->g;
    int a, c, y, i, t;
    if (obj_at(g, 0x08B4 + o) == 0) { p->dist = 0; leave_obstructed(g); return 1; }
    a = sub8(p, obj_at(g, 0x0860 + o), 0x3C, 1);
    if (a < 4) g->doorSup = obj_at(g, 0x0966 + o);
    use_vector(p, o, 0x20);
    y = p->relLog + 3;
    a = 0; c = 0;
    for (i = 0; i < y; i++) {
        int c2 = p->distF >> 7;
        p->distF = (p->distF << 1) & 255;
        t = (a << 1) | c2;
        c = t >> 8; a = t & 255;
        if (c) a = 0xFD;
    }
    a = add8(p, a, 1, c);
    if (a >= maxd) { p->dist = a; leave_obstructed(g); return 1; }
    return obstruction_along_vector(p, a);
}

/* find_route_to_target_with_angle_range_A (&3da7): try four random angles
   within the range about angleB5 and aim at the first clear one, or the longest */
static void find_route(struct P *p, int range)
{
    struct G *g = p->g;
    int half = range >> 1, base, best = 4, attempts, a, v, d;
    base = sub8(p, p->angleB5, half, range & 1);
    for (attempts = 4; attempts; attempts--) {
        v = read_site(g, 0x3DBC); a = (v & 255) & range; a = add8(p, a, base, v >> 8);
        p->angleB5 = a;
        vec_from_mag_angle(p, 0x20, a);
        v = read_site(g, 0x3DCD); d = (v & 255) & 0x1F; d = add8(p, d, 0x10, v >> 8);
        g->wlBlock >>= 1;
        if (!obstruction_along_vector(p, d)) { p->tx = p->tileX; p->ty = p->tileY; return; }
        if (p->dist >= best) { best = p->dist; g->routeBest = a; }
    }
    p->angleB5 = g->routeBest;
    vec_from_mag_angle(p, 0x20, p->angleB5);
    if (best < 0x0A) return;
    obstruction_along_vector(p, (best - 8) & 255);
    p->tx = p->tileX; p->ty = p->tileY;
}

static int path_update_needed(struct P *p, int ignoring)
{
    int y = 0x3F;
    if (!ignoring && (p->g->tbColl & 128)) y = 7;
    else if (p->ty == p->ps[2] && p->tx == p->ps[0]) y = 7;
    return (y & p->fc) == 0;
}

static int has_target(struct P *p)
{
    if (obj_at(p->g, 0x08B4 + p->target) == 0) { p->target = p->slot; p->tflags = p->slot; }
    return p->target != p->slot;
}

static void reduce_directness(struct P *p)
{
    int a = sub8(p, p->tflags, 0x40, 1);
    if (p->cy) p->tflags = a;
}

static void can_see_target(struct P *p)
{
    struct G *g = p->g;
    if (p->fc16 != 0) return;
    if (!has_target(p)) { reduce_directness(p); return; }
    if (obstruction_between(p, p->target, 0x80)) { if (p->tflags & 128) p->tflags &= 0xBF; return; }
    p->tflags |= 0xC0;
    if (!(p->tflags & 0x20)) { p->tx = obj_at(g, 0x0891 + p->target); p->ty = obj_at(g, 0x08B4 + p->target); return; }
    p->angleB5 = angle_of_object_to_this(p, p->target) ^ 0x80;
    find_route(p, 0x7F);
}

/* consider_updating_npc_path (&3d26) */
static void update_path(struct P *p)
{
    struct G *g = p->g;
    int a, v, x;
    can_see_target(p);
    if (p->tflags & 128) { if (path_update_needed(p, 1)) reduce_directness(p); return; }
    if (p->tflags & 0x40) {
        v = read_site(g, 0x3D40); a = (v & 255) & 3;
        if (a != 0) {
            a >>= 1;
            if ((a | read_rnd_byte(g, 0x3D48, 1)) == 0) { reduce_directness(p); return; }
            if (!path_update_needed(p, 0)) return;
            use_vector(p, p->target, 0x20);
            if (p->tflags & 0x20) p->angleB5 ^= 0x80;
            find_route(p, 0x3F);
            return;
        }
    }
    if (!path_update_needed(p, 0)) return;
    v = read_site(g, 0x3D6D); a = (v & 255) & 7; a = sub8(p, a, 3, v >> 8); a = add8(p, a, p->vel[0], p->cy); p->vec[0] = a;
    a = read_rnd_byte(g, 0x3D78, 0) & 7; a = sub8(p, a, 3, p->cy); a = add8(p, a, p->vel[2], p->cy); p->vec[2] = a;
    p->angleB5 = angle_from_vec(p);
    a = 0xFF; x = read_rnd_byte(g, 0x3D85, 1);
    if (x >= 8) { a = 0x7F; if (x >= 0x40) a = 0x3F; }
    find_route(p, a);
}

/* move_towards_target_with_probability_X (&31da) */
static void move_towards(struct P *p, int mag, int maxacc, int prob)
{
    struct G *g = p->g;
    if (prob < read_rnd_byte(g, 0x31DA, 1)) return;
    /* set_target_object_x_y_from_this_object_tx_ty: the target pseudo-slot at the
       centre of the target square */
    obj_set(g, 0x08A1, p->tx); obj_set(g, 0x08C4, p->ty);
    obj_set(g, 0x0890, 0x80); obj_set(g, 0x08B3, 0x80);
    use_vector(p, 16, mag);
#ifdef HOST_DEBUG
    printf("  slot %d move: angle %02x vec %02x,%02x mag %02x relLog %d signs %02x centre %02x.%02x %02x.%02x vx=%02x\n",
           p->slot, p->angleB5, p->vec[0], p->vec[2], p->mag, p->relLog, g->signs, p->cen[0], p->cenf[0], p->cen[2], p->cenf[2], p->vel[0]);
    fflush(stdout);
#endif
    weighted_accel(p, p->vec[2], 0, 2, maxacc);
    weighted_accel(p, p->vec[0], 0, 0, maxacc);
}

static int range_of_type(struct G *g, int t)
{
    int r = 10;
    do { r--; } while (t < g->tab[T_RANGES + r]);
    return r;
}

/* find_or_count_objects (&3c30): the nearest object of type a (bit 7: the
   player too) or of secondary type/range y; 0xFF if none */
static int find_or_count(struct P *p, int a, int y, int counting, int ignoring)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int includePlayer = a & 128, ptype = a & 0x7F, nearest = 0xFF, nearestDist = 0xFF, finds = 0, count = 0;
    int shuffle = read_site(g, 0x3C4A) & 15, yy, o, t, v, d;
    for (yy = 15; yy >= 0; yy--) {
        o = yy ^ shuffle;
        if (OT(O_Y, o) == 0 || o == p->slot) continue;
        t = OT(O_TYPE, o);
        if ((t == 0 && includePlayer) || t == ptype) finds = (finds | 1) & 3;
        else {
            v = t;
            if (y & 128) v = range_of_type(g, t) | 128;
            if (v != y) continue;
            finds &= 2;
        }
        count++;
        if (counting) continue;
        v = read_site(g, 0x3C96) & 255;
        if (v >= g->tab[T_FINDPROB + finds]) continue;
        if (ignoring) { obstruction_between(p, o, 0); d = p->dist; if (d >= nearestDist) continue; }
        else {
            v = read_site(g, 0x3CB2) & 255;
            if (obstruction_between(p, o, (v & 0x4F) ^ nearestDist)) continue;
            d = p->dist;
        }
        nearestDist = d; finds = (finds << 1) & 255; nearest = o;
    }
    p->count = count; p->findsCarry = (finds >> 1) & 1; p->nearestDist = nearestDist;
    return nearest;
}

static int find_a_target(struct P *p, int a, int y)
{
    int x = find_or_count(p, a, y, 0, 0);
    if (x & 128) return x;
    p->target = x; p->tflags = 0x40;
    return x;
}

static int consider_finding_target(struct P *p, int a, int y)
{
    if (p->fc16 < 0x0F) return 0xFF;
    return find_a_target(p, a, y);
}

/* avoid_object_type_Y (&3c0c): target the type, keeping away from it */
static void avoid_type(struct P *p, int t)
{
    if (!(consider_finding_target(p, t, t) & 128)) p->tflags |= 0x20;
}

static void avoid_fireballs(struct P *p) { avoid_type(p, 0x37); }

static int give_min_energy(struct P *p, int y)
{
    if (p->energy == 0) return 0;
    if (y > p->energy) p->energy = y;
    return p->energy;
}

static void change_sprite(struct P *p, int a);
static void change_sprite_base(struct P *p, int a) { change_sprite(p, (a + p->g->tab[T_OBJSPRITE + p->type]) & 255); }

/* consider_absorbing_object_touched (&3be1): 0 if the touched object was absorbed */
static int consider_absorbing(struct P *p, int type)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    if (obj_at(g, 0x0860 + p->touch) != type) return 1;
    if (touching_angle(p) & 128) return 1;
    OS(O_FLAGS, p->touch, OT(O_FLAGS, p->touch) | 0x20);
    play_sound(g, 2);
    return 0;
}

static void handle_picking_up(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int o = p->touch, a;
    if (o & 128) return;
    a = touching_angle(p);
    if (a & 128) return;
    if (!((g->tab[T_OBJPAL + OT(O_TYPE, o)] & g->held) & 128)) return;
    g->held = o;
}

static void handle_dropping(struct P *p)
{
    struct G *g = p->g;
    if (g->held & 128) return;
    g->held = 128 | (g->held >> 1);
    play_sound(g, 1);
}

static int check_reliability(struct P *p, int xi);
static int create_child(struct P *p, int type);
static void handle_dropping(struct P *p);

/* reduce_energy_of_weapon_X (&2d79): the cost of one shot, floored at nothing */
static void reduce_weapon_energy(struct P *p, int x)
{
    struct G *g = p->g;
    int c = read_site(g, SITE_DRAIN_CARRY), lo, hi;
    lo = sub8(p, g->wLo[x], g->tab[T_WEAPONCOST + x], c); c = p->cy;
    hi = sub8(p, g->wHi[x], 0, c);
    if (!p->cy) { hi = 0; lo = 0; }
    g->wLo[x] = lo; g->wHi[x] = hi;
}

/* handle_changing_weapon_or_transferring_energy (&2ce2), keys f0-f9 */
static void change_weapon(struct P *p, int key)
{
    struct G *g = p->g;
    int x = key - 1;
    if (!(g->kh[0x26] & 128)) {                   /* without SHIFT: pick it up */
        if (x != 0) {
            if (x >= 6) return;
            if (!(g->collected[8 + x] & 128)) return;   /* never collected */
        }
        g->weapon = x;
        return;
    }
    if (x != 0) {                                 /* with SHIFT: give it &800 of the current weapon's energy */
        if (x >= 6) return;
        if (!(g->collected[8 + x] & 128)) return;
    }
    if (g->wHi[x] < 8) return;
    g->wHi[x] -= 8;
    x = g->weapon;
    if (g->wHi[x] + 8 <= 255) g->wHi[x] += 8;
}

/* calculate_firing_vector_from_angle_A (&3311) then from this object's velocity */
static void firing_vector_from_angle(struct P *p, int ang)
{
    struct G *g = p->g;
    int r = read_site(g, 0x3313), a, n;
    vec_from_mag_angle(p, add8(p, r & 3, 0x40, (r >> 8) & 1), ang);
    a = add8(p, p->vel[0], p->vec[0], p->rc); a = prevent_overflow(p, a);
    n = a & 128;
    a = inv_neg(a);
    if (a >= 0x50) {
        a = add8(p, inv_neg(p->vel[0]), 0x20, 0); a = prevent_overflow(p, a);
        if (a < 0x50) a = 0x50;
    }
    p->vec[0] = n ? neg8(a) : a;
}

/* handle_firing (&2d33), SPACE */
static void handle_firing(struct P *p)
{
    struct G *g = p->g;
    int x, t;
    firing_vector_from_angle(p, g->aimFlip);
    g->fired = g->held;
    if (!(g->held & 128)) return;                 /* not while holding something */
    g->fireCool = 5;
    x = g->weapon;
    if (!check_reliability(p, x)) return;
    t = g->tab[T_WEAPONBULLET + x];
    if (t == 0) return;                           /* the jetpack and the suit do not fire */
    g->blaster = t;
    if (!(t & 128)) {                             /* the blaster discharges instead */
        if (create_child(p, t) < 0) return;
        play_sound(g, g->weapon == 1 ? 12 : (g->weapon == 2 ? 11 : 2));   /* pistol, icer, or the plasma gun's low beep */
    }
    reduce_weapon_energy(p, g->weapon);
}

/* store_object (&34b4): into the first pocket, or straight into the jetpack if
   it is a power pod; 1 if the object is still held */
static int store_object(struct P *p, int pockets)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y = g->held, i, t;
    if (y & 128) return 0;
    if (g->tab[T_SPRH + OT(O_SPRITE, y)] >= 0x38) return 1;   /* too tall to pocket */
    t = OT(O_TYPE, y);
    if (t == 0x4B) { if (g->wHi[0] + 8 <= 255) g->wHi[0] += 8; }
    else {
        if (g->pockUsed >= pockets) return 1;
        for (i = 4; i >= 1; i--) g->pocket[i] = g->pocket[i - 1];
        g->pocket[0] = t;
        g->pockUsed = (g->pockUsed + 1) & 255;
        handle_dropping(p);
    }
    OS(O_FLAGS, y, OT(O_FLAGS, y) | 0x20);
    return 0;
}

/* retrieve_object (&3504): the newest pocket back into the player's hand */
static void retrieve_object(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int x;
    firing_vector_from_angle(p, p->xFlip & 128);
    if (g->pockUsed != 0) {
        x = create_child(p, g->pocket[g->pockUsed - 1]);
        if (x < 0) return;
        g->held = x;
        play_sound(g, 14);
        OS(O_VX, x, p->vel[0]); OS(O_VY, x, p->vel[2]);
        g->pockUsed = (g->pockUsed - 1) & 255;
    }
    g->retrieve = 0x80 | (g->retrieve >> 1);
}

/* handle_throwing_object (&32d9) */
static void handle_throwing(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y = g->held, w, r, a;
    firing_vector_from_angle(p, g->aimFlip);
    if (y & 128) return;
    w = g->tab[T_OBJFLAGS + OT(O_TYPE, y)] & 7;
    handle_dropping(p);
    r = read_site(g, 0x32E9);
    a = add8(p, r & 7, g->tab[T_THROWVEL + w], (r >> 8) & 1);
    vec_from_mag_angle(p, a, p->angleB5);
    a = p->vecA;
    if (!(g->anyB & 128)) { a = add8(p, p->vecA, p->vel[2], 0); a = prevent_overflow(p, a); }
    OS(O_VY, y, a);
    a = add8(p, p->vec[0], p->vel[0], 0); a = prevent_overflow(p, a);
    OS(O_VX, y, a);
}

/* handle_teleporting (&0cc1), T */
static void handle_teleporting(struct P *p)
{
    struct G *g = p->g;
    int y;
    if (!(g->held & 128)) return;                 /* not while holding something */
    g->telRem = (g->telRem - 1) & 255;
    if (g->telRem & 128) { g->telRem = (g->telRem + 1) & 255; y = 4; }   /* none remembered: the fallback */
    else {
        g->telNext = (g->telNext - 1) & 3;
        y = g->telNext;
    }
    play_sound(g, 4);
    p->tx = g->telX[y]; p->ty = g->telY[y];
    p->flags |= 0x10; p->timer = 0x20;
}

/* handle_remembering_position (&2c3c), R */
static void remember_position(struct P *p)
{
    struct G *g = p->g;
    if (p->energy < 8) return;                    /* too hurt to remember */
    if (g->telRem < 4) g->telRem++;
    get_this_object_centre(p);
    g->telX[g->telNext] = p->cen[0];
    g->telY[g->telNext] = p->cen[2];
    g->telNext = (g->telNext + 1) & 3;
    play_sound(g, 0);
}

/* handle_scrolling_viewpoint (&2c1d), the arrow keys */
static void scroll_viewpoint(struct P *p, int key)
{
    struct G *g = p->g;
    int x = key - 15, v = (x & 2) ? g->scrollY : g->scrollX;
    if (v == g->tab[T_SCROLLLIMIT + x]) return;
    v = (v + g->tab[T_SCROLLDELTA + x]) & 255;
    if (x & 2) g->scrollY = v; else g->scrollX = v;
    play_sound(g, 8);
}

static void do_action(struct P *p, int i)
{
    struct G *g = p->g;
    if (i == 34) p->acc[0] = (p->acc[0] + 1) & 255;
    else if (i == 33) p->acc[0] = (p->acc[0] - 1) & 255;
    else if (i == 37) p->acc[2] = (p->acc[2] + 1) & 255;
    else if (i == 35) { p->acc[2] = (p->acc[2] - 1) & 255; if (g->jetOk & 128) p->state |= 15; }
    else if (i == 36) handle_jumping(p);
    else if (i == 21) use_booster(p);
    else if (i == 22) p->state |= 15;
    else if (i == 23) g->facing ^= 128;
    else if (i == 14) { g->aim = g->aimVel = 0; p->aimAccT = (p->aimAccT - 1) & 255; }
    else if (i == 20) p->aimAccT = (p->aimAccT - 1) & 255;
    else if (i == 19) p->aimAccT = (p->aimAccT + 1) & 255;
    else if (i == 30) handle_picking_up(p);
    else if (i == 29) handle_dropping(p);
    else if (i >= 1 && i <= 10) change_weapon(p, i);
    else if (i == 13) handle_firing(p);
    else if (i == 31) store_object(p, 4);                     /* S: pocket it for good */
    else if (i == 12) { if (!store_object(p, 5)) g->retrieve &= 0x7F; }   /* G: pocket it to fetch back */
    else if (i == 28) handle_throwing(p);
    else if (i == 26) handle_teleporting(p);
    else if (i == 27) remember_position(p);
    else if (i >= 15 && i <= 18) scroll_viewpoint(p, i);
    else if (i == 24) { if (g->collected[17] & 128) { g->whistle2 = p->slot; play_sound(g, 1); play_sound(g, 9); } }
    else if (i == 25) { if (g->collected[16] & 128) { g->whistle1 = 0x80 | (g->whistle1 >> 1); play_sound(g, 1); play_sound(g, 10); } }
    else if (i == 0 || i == 11 || i == 32 || i == 38) ;       /* pause, save, sound, shift: nothing here */
    else fault(g, 4, i);
}

static void process_actions(struct P *p)
{
    struct G *g = p->g;
    int i, k;
    for (i = 0x26; i >= 0; i--) {
        k = g->kh[i];
        if (!(k & 128)) continue;
        if ((k & 0xC0) == 0xC0 && g->tab[T_NOREPEAT + i]) continue;
        do_action(p, i);
    }
}

static int check_reliability(struct P *p, int xi)
{
    struct G *g = p->g;
    int hi = g->wHi[xi], c, a, i, nc, da;
    if (hi >= 4) return 1;
    c = xi == 0;
    a = hi;
    for (i = 0; i < 3; i++) { nc = a & 1; a = (c << 7) | (a >> 1); c = nc; }
    da = read_site(g, SITE_RELIABILITY);
    return a >= da;
}

static void drain_jetpack(struct P *p)
{
    struct G *g = p->g;
    int c = read_site(g, SITE_DRAIN_CARRY), lo, hi;
    lo = sub8(p, g->wLo[0], g->tab[T_WEAPONCOST + 0], c); c = p->cy;
    hi = sub8(p, g->wHi[0], 0, c);
    if (!p->cy) { hi = 0; lo = 0; }
    g->wLo[0] = lo; g->wHi[0] = hi;
}

static void rotating_player(struct P *p)
{
    struct G *g = p->g;
    int a, a2, c, hit = 0, n;
    g->immob = (g->immob - 1) & 255;
    a2 = (g->angle << 1) & 255;
    if (g->tbColl & 128) { a = g->preAng; hit = 1; }
    else if (p->touch & 128) a = g->rotVel;
    else { a = 0x40; hit = 1; }
    if (hit) {
        a = (a << 1) & 255;
        a = sub8(p, a, a2, 1); c = p->cy;
        a = (c << 7) | (a >> 1);
        n = a & 128;
        a = (g->preMag >> 2) | 1;
        if (n) a = neg8(a);
        a = add8(p, a, g->rotVel, 0);
        a = keep_range(a, 0x20);
    }
    if (g->frm % 4 == 0 && a >= 4 && a < 0xFD) a = seven_eighths(a);
    g->rotVel = a;
    g->angle = (g->angle + a) & 255;
}

static void angle_and_facing(struct P *p)
{
    struct G *g = p->g;
    int xi, c = 0, a, yy, kept = 0;
    p->vec[0] = p->acc[0]; p->vec[2] = p->acc[2];
    xi = ((p->acc[2] != 0) << 1) | (p->acc[0] != 0);
    if (xi != 0 && (g->jetOk & 128)) { a = angle_from_vec(p); c = 1; }
    else {
        a = 0xC0;
        if (g->lying & 128) a = (g->facing & 128) ? 0x83 : 0xFD;
    }
    a = sub8(p, a, g->angle, c);
    yy = a;
    if (xi == 2) {
        a = sub8(p, a, 0x74, 1);
        if (a < 0x18) { yy = 0; xi = 0; kept = 1; }
    }
    if (!kept && (p->acc[0] == 0 || !(p->upright & 128))) xi = 0;
    c = jumping(p);
    a = yy;
    if (!c && !(g->lying & 128)) a = 0;
    a = asr(p, a); a = asr(p, a); c = p->cy;
    g->angle = add8(p, a, g->angle, c);
    a = g->angle ^ p->acc[0] ^ 128;
    if (!(((xi - 1) & 255) & 128)) g->facing = a;
}

/* update_walking_state (&3a6d) for walking type x: the low nibble of the state
   counts the frames since a surface shallow enough to walk on */
static int walk_state(struct P *p, int x)
{
    struct G *g = p->g;
    int c = 1, a;
    if (!(p->upright & 128)) { p->state |= 15; return p->state; }
    if ((g->tbColl | p->objCY) & 128) c = inv_neg(p->tileAng) >= g->tab[T_WALKANG256 + (x & 255)];
    a = p->state & 0xF0;
    if (!c) { p->state = a; return p->state; }
    if ((a ^ p->state) < 15) p->state = (p->state + 1) & 255;
    return p->state;
}

static void walk_along(struct P *p, int spd, int yy, int maxacc)
{
    struct G *g = p->g;
    int a, c, accl, angl;
    a = (g->relTX & 128) ? neg8(spd) : spd;
    a = sub8(p, a, p->vel[0], 1);
    accl = weight_limit(p, a, p->cy, p->ov, yy, maxacc);
    a = (accl & 128) ^ p->tileAng;
    a = add8(p, a, 0x40, 0);
    c = a >> 7;
    if (g->relTX == 0) accl = 0;
    if (!c) angl = add8(p, 0x10, p->tileAng, 0); else angl = add8(p, 0x6F, p->tileAng, 1);
    vec_from_mag_angle(p, inv_neg(accl), angl);
    p->acc[2] = p->vecA; p->acc[0] = p->vec[0];
    p->vel[2] = seven_eighths(seven_eighths(p->vel[2]));
}

static void climb_steep(struct P *p, int spd, int yy, int maxacc)
{
    struct G *g = p->g;
    int a = (g->relTY & 128) ? neg8(spd) : spd;
    weighted_accel(p, a, yy, 2, maxacc);
    p->acc[0] = (p->tileAng & 128) ? 8 : 0xF8;
    p->vel[0] = seven_eighths(seven_eighths(seven_eighths(p->vel[0])));
}

/* update_walking_npc_or_player (&3b0b) for walking type x */
static void walk_npc(struct P *p, int x, int maxacc, int yy)
{
    struct G *g = p->g;
    int a, c, spd;
    a = walk_state(p, x);
    if (a & 15) return;
    a = inv_neg(p->tileAng);
    c = a >= g->tab[T_WALKMAXANG + x];
    a = sub8(p, a, 0x2C, c);
    c = a >= 0x28;
    spd = g->walkSpd;
    if (!c) climb_steep(p, spd, yy, maxacc); else walk_along(p, spd, yy, maxacc);
}

static void walk_player(struct P *p) { walk_npc(p, 0, p->g->maxAcc0, p->g->npcW0); }

static void update_walking(struct P *p)
{
    struct G *g = p->g;
    int c, yy, a;
    g->walkSpd = 0x1F;
    c = p->fc16 >= 2;
    yy = sub8(p, p->weight, 5, c); c = p->cy;
    if (c && jumping(p) && !(g->anyB & 128)) {
        for (;;) {
            p->acc[2] = halve_toward_zero(p, p->acc[2]); p->acc[0] = halve_toward_zero(p, p->acc[0]);
            yy = (yy - 1) & 255;
            if (yy & 128) break;
        }
        walk_player(p);
        return;
    }
    a = 0x0F;
    yy = (yy + 1) & 255;
    for (;;) {
        c = a & 1; a >>= 1;
        yy = (yy - 1) & 255;
        if (yy & 128) break;
    }
    a = add8(p, a, 1, c);
    g->relTX = p->acc[0];
    if (p->acc[0] == 0) { g->walkSpd = 0; a = 1; }
    g->maxAcc0 = a;
    if (!jumping(p)) p->acc[0] = 0;
    walk_player(p);
}

static void change_sprite(struct P *p, int a)
{
    struct G *g = p->g;
    int d, c;
    if (a == p->spr) return;
    p->spr = a;
    d = sub8(p, p->siz[2], g->tab[T_SPRH + a], 1); c = p->cy;
    d = ((c << 7) | (d >> 1)) ^ 128;
    add_to_pos(p, 2, d, d & 128);
    d = sub8(p, p->siz[0], g->tab[T_SPRW + a], 1); c = p->cy;
    d = ((c << 7) | (d >> 1)) ^ 128;
    add_to_pos(p, 0, d, d & 128);
}

static int sprite_offset(struct P *p, int modulus, int shifts)
{
    int a = inv_neg(p->vel[0]), b = inv_neg(p->vel[2]), c;
    if (b > a) a = b;
    a >>= shifts + 1;
    a = add8(p, a, p->timer, 1);
    c = 1;
    for (;;) { a = sub8(p, a, modulus, c); c = p->cy; if (!c) break; }
    a = add8(p, a, modulus, c);
    p->timer = a;
    return a;
}

static void sprite_from_angle(struct P *p, int a)
{
    int c = 0, i, h, stg;
    for (i = 0; i < 5; i++) { c = a & 1; a >>= 1; }
    a = add8(p, a, 0, c);
    if (!(p->xFlipP & 128)) { a ^= 7; a = add8(p, a, 1, 0); }
    h = a;
    c = (a & 4) == 4;
    p->xFlip = (c << 7) | ((a & 4) >> 1);
    p->yFlip = p->xFlip ^ p->xFlipP;
    a = h & 3;
    if (a != 2) { change_sprite(p, a); return; }
    if ((inv_neg(p->vel[0]) >> 1) == 0) { change_sprite(p, 4); return; }
    if (jumping(p)) { change_sprite(p, 2); return; }
    a = sprite_offset(p, 8, 3);
    stg = a >> 1;
    if ((p->vel[0] ^ p->xFlip) & 128) stg ^= 3;
    change_sprite(p, (stg + 4) & 255);
}

static void sprite_and_palette(struct P *p, int a, int yy)
{
    struct G *g = p->g;
    int flsh, pal, c, t;
    if (!(p->child & 128)) { p->xFlipP = yy; sprite_from_angle(p, a); }
    flsh = (((p->fc & 0x1F) << 1) & 255) >= p->energy;
    pal = p->palDefault;
    c = check_reliability(p, 5);
    t = ((c << 7) | (pal >> 1)) & g->suitCol;
    pal = (t & 128) ? 0x33 : 0x3E;
    if (flsh) pal = p->pal ^ 0x0B;
    p->pal = pal;
}

static void angle_facing_sprite(struct P *p)
{
    struct G *g = p->g;
    int a, c, old, ax, ay, drain = 1;
    p->acc[0] = (p->acc[0] << 1) & 255;
    c = p->acc[2] >> 7; p->acc[2] = (p->acc[2] << 1) & 255;
    if (g->frm % 16 == 0) {
        a = add8(p, p->energy, 4, c);
        if (!p->cy) p->energy = a;
        c = check_reliability(p, 0);
        old = g->jetOk; g->jetOk = (c << 7) | (old >> 1); c = old & 1;
    }
    a = sub8(p, 0x10, p->energy, c);
    if (p->cy) g->immob = a;
    if (g->immob >= 6) g->jetOk >>= 1;
    if (g->tImmob) { g->tImmob = (g->tImmob - 1) & 255; g->jetOk >>= 1; }
    g->lying >>= 1;
    a = sub8(p, g->angle, 0xCF, 1); c = a >= 0xE1;
    p->upright = ((c << 7) | (a >> 1)) & p->upright;
    ax = p->acc[0]; ay = p->acc[2];
    if (ay == 0) {
        if (ax == 0) g->lying = g->surr | g->wedged | g->kh[0x16];
        if (jumping(p)) {
            if (g->anyB & 128) p->vel[2] = seven_eighths(seven_eighths(seven_eighths(p->vel[2])));
        } else drain = 0;
    }
    if (drain && (g->jetOk & 128) && (p->acc[0] | p->acc[2]) != 0) {
        /* add_jetpack_thrust_particles (&1f3d): where the flame leaves the suit
           depends on how the suit is lying, and the drain follows it */
        g->jetFlags = (p->spr >= 2) ? 0xED : 0xEB;
        add_particles_t(p, 1, p->ps[0], p->ps[2], 0x86, 0x01, 0x0B);
        if (!(g->frm & 1) && ((g->frm & 7) == 0 || (g->kh[0x15] & 128))) drain_jetpack(p);
    }
    if (g->immob) rotating_player(p); else angle_and_facing(p);
    update_walking(p);
    if (!(g->jetOk & 128)) { p->acc[2] = 0; if (jumping(p)) p->acc[0] = 0; }
    sprite_and_palette(p, g->angle, g->facing);
}

static void aiming_angle(struct P *p)
{
    struct G *g = p->g;
    int a = p->aimAccT;
    if (a) { a = add8(p, a, g->aimVel, 0); a = keep_range(a, 0x10); }
    g->aimVel = a;
    a = add8(p, a, g->aim, 0);
    a = keep_range(a, 0x3F);
    g->aim = a;
    if (p->xFlip & 128) a = ((a ^ 0x7F) + 1) & 255;
    g->aimFlip = a;
}

static void update_explosion(struct P *p);

static void update_player(struct P *p)
{
    p->g->eastOf76 = ((p->ps[0] >= 0x76) << 7) | (p->g->eastOf76 >> 1);
    struct G *g = p->g;
    long long *obj = g->obj;
    int heldBefore;
    if (!(p->touch & 128) && OT(O_TYPE, p->touch) == 3) g->held = p->touch;
    g->fired = 0x80 | (g->fired >> 1);            /* nothing fired, unless firing says so */
    if (!(g->retrieve & 128)) retrieve_object(p);
    heldBefore = g->held;
    process_actions(p);
    if (!(p->flags & 0x10)) angle_facing_sprite(p);
    aiming_angle(p);
    if (!(heldBefore & 128)) {
        int a = p->xFlip ^ p->flags, w;
        if (a & 128) {
            w = g->tab[T_SPRW + OT(O_SPRITE, heldBefore)];
            if (!(p->xFlip & 128)) w = neg8(w);        /* invert_if_positive on N of &37 */
            add_to_pos(p, 0, w, (p->flags & 128) != 0);
        }
    }
    g->fireCool = (g->fireCool - 1) & 255;
    if (g->fireCool == 0) g->kh[13] >>= 1;
    if (g->blaster & 128) {                       /* the blaster goes on discharging for five frames */
        g->blaster = (g->blaster + 1) & 255;
        play_sound(g, 38);
        g->expTimer = 0xCE;
        p->tdataOff = 0x0A;
        update_explosion(p);
    }
}

/* ---- the other objects' routines ---------------------------------------------------- */

static void update_collectable(struct P *p)
{
    struct G *g = p->g;
    if (g->held == p->slot) {
        g->collected[p->type - 0x51] = (g->collected[p->type - 0x51] - 1) & 255;
        play_sound(g, 39);
        p->flags |= 0x20;
        return;
    }
    if (!(p->touch & 128)) p->energy &= 0x7F;
    if (!(p->energy & 128)) return;
    p->vel[0] = p->vel[2] = 0;
    set_position_from_previous(p);
}

static void update_giant_block(struct P *p)
{
    if (p->waterline >= 0xC0) p->acc[2] = (p->acc[2] - 2) & 255;
}

/* update_bird (&4631), with the whistling (kind 1) and invisible (kind 2) entries */
static void update_bird(struct P *p, int kind)
{
    struct G *g = p->g;
    int a, c, x = p->type - 0x2E;
    if (kind == 1) read_rnd_byte(g, 0x4621, 1);            /* 1 in 256: whistle two, a sound */
    else {
        if (kind == 2 && p->state == 0) p->visibility >>= 1;
        if ((read_site(g, 0x4631) & 0x3F) == 0) play_sound(g, 30);   /* 1 in 64: the bird calls */
    }
    if (p->touch == 0) damage_slot(p, 0, g->tab[T_BIRDDMG + x]);
    a = give_min_energy(p, g->tab[T_BIRDEN + x]);
    p->energy = a & 0x7F;
    c = (p->flags & 8) == 8;
    p->state = (c << 7) | (p->state >> 1);
    if (p->state == 0) {
        a = sprite_offset(p, 0x14, 3) >> 2;
        if (a == 4) a = 2;
        change_sprite_base(p, a);
        consider_absorbing(p, 0x11);
        consider_finding_target(p, 0x11, 0);
        avoid_fireballs(p);
        update_path(p);
        move_towards(p, 0x40, 8, 0x40);
        p->acc[2] = (p->acc[2] - 1) & 255;
    }
    if (!(g->inWater & 128)) {
        p->vel[0] = seven_eighths(seven_eighths(p->vel[0]));
        p->vel[2] = seven_eighths(seven_eighths(p->vel[2]));
    }
}

/* ---- the walking creatures ------------------------------------------------------------- */

static void remove_for_touching_and_targeting(struct G *g, int a);

/* check_for_space_at_position (&39c5): the unobstructed space below the test
   point (xf, yf) of the tile at (tileX, tileY), 0xFF for a tile or more */
static int space_at_position(struct P *p, int xf, int yf)
{
    struct G *g = p->g;
    int sec = xf >> 5, space = 0, a, c, c2, bnd;
    g->mode = 0x40;                              /* only the door routines want to know */
    a = (yf & 0xF8) | 4;
    for (;;) {
        yf = a;
        set_obs_vars(p, 0);
        a = add8(p, pattern(p, p->tAddr, sec), p->tYoff, 0);
        if (p->cy) a = 0xFF;
        bnd = a;
        c = a >= yf; c2 = a & 1;
#ifdef HOST_DEBUG
        printf("    space: tile %02x,%02x sec %d yf %02x bnd %02x yoff %02x flip %02x space %02x\n", p->tileX, p->tileY, sec, yf, bnd, p->tYoff, p->tFlip, space);
        fflush(stdout);
#endif
        a = ((c << 7) | (a >> 1)) ^ p->tFlip;
        if (!(a & 128)) break;                   /* the test point is obstructed */
        if (!(p->tFlip & 128) && ((bnd + 1) & 255) != 0) {
            a = sub8(p, bnd, yf, c2);
            a = add8(p, a, space, p->cy);
            if (p->cy) a = 0xFF;
            space = a;
            break;
        }
        /* the space to the bottom of this tile counts, then the tile below */
        a = add8(p, yf ^ 255, space, c2);
        if (p->cy) { space = 0xFF; break; }
        space = a;
        p->tileY = (p->tileY + 1) & 255;
        a = 4;
    }
    return space;
}

/* check_for_space_to_side_of_object (&399c): half a tile ahead of the object,
   towards its target, half a tile above its bottom */
static int space_to_side(struct P *p)
{
    struct G *g = p->g;
    int a, c, c1, xf, yf;
    get_this_object_centre(p);
    xf = sub8(p, p->cenf[0], 0x7F, p->cenC); c = p->cy;
    p->tileX = sub8(p, p->cen[0], 0, c);
    g->relTY = sub8(p, p->ty, p->ps[2], 0);
    g->relTX = sub8(p, p->tx, p->ps[0], 1);
    if (!(g->relTX & 128)) p->tileX = (p->tileX + 1) & 255;
    /* "half the object's width": the byte is the plotting code's, the width
       of the last sprite it drew after clipping and its own adjustments.  A
       trace hands it over; the game uses the last plotted object's width */
    a = g->feedMode ? read_site(g, SITE_PLOTW) & 255 : g->lastPlotW;
    c = a & 1; a >>= 1;
    a = add8(p, a, p->mxf[2], c); c1 = p->cy;
    yf = sub8(p, a, 0x7F, c1); c = p->cy;
    a = sub8(p, p->mxp[2], 0, c);
    p->tileY = add8(p, a, 0, c1);
#ifdef HOST_DEBUG
    printf("  slot %d side: centre %02x.%02x cenC %d relTX %02x rawW %02x max %02x.%02x -> tile %02x,%02x test %02x.%02x\n",
           p->slot, p->cen[0], p->cenf[0], p->cenC, g->relTX, p->rawW, p->mxp[2], p->mxf[2], p->tileX, p->tileY, xf, yf);
    fflush(stdout);
#endif
    a = space_at_position(p, xf, yf);
#ifdef HOST_DEBUG
    printf("  slot %d side: space %02x frm %02x\n", p->slot, a, g->frm);
    fflush(stdout);
#endif
    return a;
}

/* set_npc_jumping_with_speed_A (&3a5b): head for the target at that speed and push off */
static void set_npc_jumping_speed(struct P *p, int spd)
{
    move_towards(p, spd, spd, 0xFF);
    p->acc[2] = sub8(p, p->acc[2], 0x0A, p->rc);
    p->state |= 15;
}

/* set_npc_jumping (&3a59): at the walking speed */
static void set_npc_jumping(struct P *p) { set_npc_jumping_speed(p, p->g->walkSpd); }

/* update_walking_npc_and_check_for_obstacles (&3ae1): walk; at a wall or a drop
   maybe turn away from the target, maybe jump.  1 if not jumping */
static int update_walking_npc_and_check(struct P *p, int x)
{
    struct G *g = p->g;
    int a, blocked = 0;
    g->relTY = sub8(p, p->ty, p->ps[2], 0);
    g->relTX = sub8(p, p->tx, p->ps[0], 1);
    walk_npc(p, x, g->tab[T_WALKMAXACC + x], g->tab[T_WALKWEIGHT + x]);
    if (g->frm % 4 == 0) { a = space_to_side(p); blocked = (a == 0 || a == 0xFF); }
    if (blocked) {
        a = read_site(g, 0x3AE9) & 255;
        if (a < g->tab[T_WALKTURN + x]) goto consider_jump;
        a = (g->relTX & 128) ? 1 : 0xFF;
        p->tx = add8(p, a, p->ps[0], 0);
    }
    a = read_site(g, 0x3AFC) & 255;
    if (a >= g->tab[T_WALKJUMP + x]) return 1;
consider_jump:
    if (p->state & 15) return 1;                 /* not on a surface it can walk on */
    set_npc_jumping(p);
    return 0;
}

/* set_npc_facing_tile_collision (&256d): face the surface just hit */
static void set_npc_facing_tile_collision(struct P *p)
{
    if (p->g->tbColl & 128) p->xFlip = p->tileAng ^ 255;
}

/* consider_flipping_object_to_match_velocity_x_A (&257a): 1 chance in prob + 1 */
static void consider_flipping(struct P *p, int prob)
{
    if ((read_rnd_byte(p->g, 0x257A, 0) & prob) == 0 && p->vel[0] != 0) p->xFlip = p->vel[0];
}

/* check_for_npc_stimuli (&27c9) for stimuli type x: every 64 frames look for
   what the creature fears, wants, eats and calls home; then let what it has
   felt this frame nudge its mood the way its responses say */
static void check_for_npc_stimuli(struct P *p, int x)
{
    struct G *g = p->g;
    int a, c, t, i, resp, xx;
    p->stimuli = 0;
    p->npcType = x;
    if ((p->fc & 0x3F) == 0) {
        t = find_a_target(p, g->tab[T_PHOBIA + x], g->tab[T_NPCTARGET + x]);
        if (!(t & 128)) {
            p->stimuli = ((p->stimuli << 1) | p->findsCarry) & 255;
            c = p->stimuli == 0;
            p->stimuli = ((p->stimuli << 1) | c) & 255;
        }
        if ((p->state & 0xC0) == 0x80) {           /* mood minus two */
            c = 0;
            if (p->stimuli) {
                p->tflags |= 0x20;                   /* avoid_target */
                c = read_site(g, 0x27F6) & 128;
            }
            if (!c) { a = g->tab[T_NPCHOME + x]; find_a_target(p, a, a); }
        }
        if (!(read_site(g, 0x2804) & 128)) { a = g->tab[T_NPCFOOD + x]; find_a_target(p, a, a); }
    }
    p->stimuli = (p->stimuli << 1) & 255;
    if (consider_absorbing(p, g->tab[T_NPCFOOD + x]) == 0) p->stimuli = (p->stimuli + 1) & 255;
    resp = g->tab[T_NPCRESP + x];
    a = p->stimuli;
    a = ((a << 1) | ((p->flags & 8) == 8)) & 255;
    a = ((a << 1) | (g->expTimer == 0xCF)) & 255;
    a = ((a << 1) | (g->flood >= 0x80)) & 255;
    a = ((a << 1) | (p->fc == 0xFF)) & 255;
    a &= read_rnd_byte(g, 0x283F, 1);
    if (a == 0) return;
    xx = 0;
    for (i = 0; i < 7; i++) {
        c = a & 1; a >>= 1;
        if (c) { xx--; if (resp & 128) xx += 2; }
        resp = (resp << 1) & 255;
    }
    if (xx == 0) return;
    a = (xx < 0) ? 0xC0 : 0x40;
    a = add8(p, a, p->state, 0);
    if (!p->ov) p->state = a;
}

/* ---- making objects ---------------------------------------------------------------------- */

/* get_object_Y_distance_from_screen_centre (&355b) */
static int distance_from_screen_centre(struct P *p, int y)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int a, dx;
    a = sub8(p, OT(O_X, y), 4, 1); a = sub8(p, a, g->scr[0], p->cy); dx = inv_neg(a);
    a = sub8(p, OT(O_Y, y), 1, 0); a = sub8(p, a, g->scr[1], p->cy); a = inv_neg(a);
    a = add8(p, a, dx, 0);
    return (p->cy << 7) | (a >> 1);
}

/* create_new_object_if_Y_slots_free (&1e62): a new object of type t where this
   one is, in a free slot (ySlots of them must be free) or, for ySlots 0, in the
   slot of the furthest replaceable object; the slot, or -1 */
static int create_new_object(struct P *p, int type, int ySlots)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y, x;
    if (ySlots == 0) {
        int furthest = 0, most = 0, d;
        for (y = 15; y >= 1; y--) {
            if (y == p->slot) continue;
            if (OT(O_Y, y) == 0) goto create;
            if ((g->tab[T_OBJFLAGS + OT(O_TYPE, y)] & 0x50) != 0x40) continue;
            if (!(OT(O_FLAGS, y) & 1)) continue;         /* not one that is plotted */
            d = distance_from_screen_centre(p, y);
            if (d < furthest) continue;
            furthest = d; most = y;
        }
        if (most == 0) return -1;
        y = most;
        if (g->tab[T_OBJFLAGS + OT(O_TYPE, y)] & 8) {    /* it goes back into its nest */
            int o = OT(O_TDATA, y);
            g->tert[o] = (g->tert[o] + 4) & 255;
        }
        remove_for_touching_and_targeting(g, y);
    } else {
        y = 0; x = ySlots;
        for (;;) {
            y++;
            if (y >= 16) return -1;
            if (OT(O_Y, y) != 0) continue;
            x--;
            if (x == 0) break;
        }
    }
create:
    OS(O_PALETTE, y, g->tab[T_OBJPAL + type] & 0x7F);
    OS(O_SPRITE, y, g->tab[T_OBJSPRITE + type]);
    OS(O_FLAGS, y, 5);
    OS(O_TOUCHING, y, 0xFF);
    OS(O_TARGET, y, y);
    OS(O_TDATA, y, 0); OS(O_STATE, y, 0); OS(O_TIMER, y, 0); OS(O_VX, y, 0); OS(O_VY, y, 0);
    OS(O_TYPE, y, type);
    OS(O_ENERGY, y, g->tab[T_RANGEENERGY + range_of_type(g, type)]);
    OS(O_X, y, p->ps[0]); OS(O_Y, y, p->ps[2]);
    return y;
}

/* create_child_object (&33b8): a new object of type t moving with vec, level
   with this object's middle and just beyond its edge; the slot, or -1 */
static int create_child(struct P *p, int type)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y = create_new_object(p, type, 1), a, c, spr, rel, same, yy, xf;
    if (y < 0) return -1;
    p->child = 0x80 | (p->child >> 1);
    OS(O_FLAGS, y, ((p->yFlip & 128) >> 1) | 5);
    OS(O_VX, y, p->vec[0]); OS(O_VY, y, p->vec[2]);
    spr = OT(O_SPRITE, y);
    a = sub8(p, p->siz[2], g->tab[T_SPRH + spr], 1);
    c = a & 1; a >>= 1;
    a = add8(p, a, p->pf[2], c); OS(O_YF, y, a);
    a = add8(p, p->ps[2], 0, p->cy); OS(O_Y, y, a);
    a = sub8(p, p->vel[0], p->vec[0], 1); rel = prevent_overflow(p, a);
    same = (rel ^ p->vel[0]) & 128;
    if (!(rel & 128)) { a = sub8(p, 0xE9, g->tab[T_SPRW + spr], 0); yy = 0xFF; }
    else { a = add8(p, p->siz[0], 0x18, 0); yy = 1; }
    if (!p->cy) yy = (yy - 1) & 255;
    xf = add8(p, a, p->pf[0], 0);
    yy = add8(p, yy, p->ps[0], p->cy);
    a = rel;
    if (!same) a = sub8(p, 1, p->vec[0], 0);
    if (a & 128) yy = (yy - 1) & 255;
    xf = add8(p, a, xf, 0); OS(O_XF, y, xf);
    if (p->cy) yy = (yy + 1) & 255;
    OS(O_X, y, yy);
    return y;
}

/* create_projectile (&33ab): fired the way this object faces, at least &50
   fast along x however this object moves */
static int create_projectile(struct P *p, int xv, int yv, int type)
{
    int a, n;
    p->vec[0] = (p->xFlip & 128) ? neg8(xv) : xv;
    p->vec[2] = yv;
    a = add8(p, p->vel[0], p->vec[0], 0); a = prevent_overflow(p, a);
    n = a & 128;
    a = inv_neg(a);
    if (a >= 0x50) {
        a = add8(p, inv_neg(p->vel[0]), 0x20, 0); a = prevent_overflow(p, a);
        if (a < 0x50) a = 0x50;
    }
    if (n) a = neg8(a);
    p->vec[0] = a;
    return create_child(p, type);
}

/* check_if_object_hit_by_other_control (&0bc7): 0 when the player has shot a
   control device of type t that this object can see, close enough and squarely
   enough on; 1 otherwise.  The game returns this in the carry, so the sense is
   inverted from what reads naturally. */
static int hit_by_control(struct P *p, int t)
{
    struct G *g = p->g;
    int x = g->fired, a;
    if (x & 128) return 1;                            /* nothing was fired */
    if ((t ^ obj_at(g, 0x0860 + x)) != 0) return 1;   /* or not this kind of control */
    if (obstruction_between(p, x, 0x18)) return 1;    /* three tiles, and in sight */
    a = angle_of_object_to_this(p, x);                /* which leaves the carry set */
    a = sub8(p, a, g->aimFlip, 1);
    a = sub8(p, a, 0x80, p->cy);
    a = inv_neg(a);                                   /* and this leaves it clear */
    a = add8(p, a, p->dist, 0);                       /* further off, aim less exactly */
    return a >= 0x18;                                 /* too wide an angle */
}

/* update_remote_control_device (&4351): when the player shoots it, it answers
   with a sound and a puff of aim particles.  Neither is the kernel's business,
   but putting the particles on the player's side turns the device round, and
   the vector it fires them along costs a random draw. */
static void update_remote_control_device(struct P *p)
{
    struct G *g = p->g;
    if (p->slot != g->fired) return;                  /* &0bbf: only the one just shot */
    play_sound(g, 22);
    firing_vector_from_angle(p, g->aimFlip);
    p->xFlip ^= 0x80;
}

/* update_cannon (&40ee): fires a cannonball when its own control device is shot */
static void update_cannon(struct P *p)
{
    if (!hit_by_control(p, 0x4F)) create_projectile(p, 0x40, 0, 0x15);
    consider_flipping(p, 0x0F);
}

/* ---- firing at a target ------------------------------------------------------------------ */

/* calculate_firing_vector_from_distance (&3355): a vector of speed a3/4 towards
   object x, lifted for the distance the projectile will fall; 1 if it cannot */
static int firing_vector_from_distance(struct P *p, int a3, int x)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int fv = a3 >> 2, df, a, c, c2, i, y, yv, xv, m;
    use_vector(p, x, fv);
    if (p->relLog >= 6) return 1;                /* sixteen tiles or more away */
    fv >>= 2;
    df = (p->distF << 1) & 255;
    a = 0; c = df >> 7; df = (df << 1) & 255;
    for (i = 0; i < 8; i++) {                    /* (4 * distance) / (speed / 4) */
        a = ((a << 1) | c) & 255;
        if (a >= fv) { a = (a - fv) & 255; c = 1; } else c = 0;
        c2 = df >> 7; df = ((df << 1) | c) & 255; c = c2;
    }
    y = (p->relLog + 4) & 255;
    a = 0;
    for (i = 0; i < y; i++) { c = df >> 7; df = (df << 1) & 255; a = ((a << 1) | c) & 255; }
    a ^= 255;
    a = add8(p, a, p->vec[2], 1);
    if (p->ov) return 1;
    p->vec[2] = a;
    yv = inv_neg(a);
    a = add8(p, OT(O_VX, x), p->vec[0], 0); a = prevent_overflow(p, a);
    p->vec[0] = a;
    xv = inv_neg(a);
    m = xv >= yv ? xv : yv;
    return m >= a3;                              /* that would be firing too fast */
}

/* fire_at_target (&278a): negative when it fired or could not (the routine
   ends on LDY #&ff, so that is the sign the caller tests, not the velocity in
   A), positive when the target is behind (the caller then turns round) */
static int fire_at_target(struct P *p, int x, int projType)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int r = read_site(g, 0x278A), a, slot;
    a = add8(p, r & 0x3F, 0xB4, (r >> 8) & 1);   /* a speed between &2d and &3c, times four */
    if (firing_vector_from_distance(p, a, x)) return 0x80;
    a = sub8(p, p->vel[0], p->vec[0], 1); a = prevent_overflow(p, a);
    a ^= p->xFlip;
    if (!(a & 128)) return a;
    p->vec[2] ^= read_rnd_byte(g, 0x27A7, 3) & 3;
    slot = create_child(p, projType);
    if (slot < 0) return 0x80;
    OS(O_TARGET, slot, x);
    a = (read_site(g, 0x27BA) & 7) ^ OT(O_VX, slot);
    OS(O_VX, slot, a);
    return 0x80;
}

/* find_a_target_and_fire_at_it_with_likelihood_A_divided_by_four (&276d): at
   the nearest object of primary type ta (bit 7: the player too) or secondary
   type or range ty */
static void find_and_fire(struct P *p, int like, int projType, int ta, int ty)
{
    struct G *g = p->g;
    int a, x;
    a = ((like >> 2) + 2 + ((like >> 1) & 1)) & 255;
    if (a < read_rnd_byte(g, 0x2771, 1)) return;
    x = find_or_count(p, ta, ty, 0, 0);
    if (x & 128) return;
    a = fire_at_target(p, x, projType);
    if (!(a & 128)) p->xFlip ^= 0x80;
}

/* ---- exploding --------------------------------------------------------------------------- */

/* change_object_type (&3286): the type's palette and sprite */
static void change_type(struct P *p, int t)
{
    struct G *g = p->g;
    p->type = t;
    p->pal = g->tab[T_OBJPAL + t] & 0x7F;
    change_sprite(p, g->tab[T_OBJSPRITE + t]);
}

/* turn_object_into_fireball_of_duration_seven / _two (&4ab6) */
static void turn_into_fireball(struct P *p, int d)
{
    p->timer = d; p->energy = d;
    p->target = 0;
    change_type(p, 0x37);
}

/* explode_object_with_duration_A_but_no_sound (&40e2) */
static void explode_with_duration(struct P *p, int d)
{
    play_sound(p->g, 17);
    p->tdataOff = d;
    p->type = 0x44;
    p->g->expTimer = 0xCE;
}

/* explode_object_with_squeal (&40c5): a duration from the type's energy */
static void explode_with_squeal(struct P *p)
{
    struct G *g = p->g;
    int e = g->tab[T_RANGEENERGY + range_of_type(g, p->type)];
    play_sound(g, 3);                            /* &40c5 play_squeal */
    explode_with_duration(p, ((e >> 5) + 3 + ((e >> 4) & 1)) & 255);
}

/* consider_teleporting_damaged_player (&4096): the player is the one object
   that cannot explode.  Out of energy it is given a single point back, and
   then half the time it is teleported away; the rest of the time it may
   fumble whatever it was carrying back into its hand.  The game also counts
   the death on its panel, which is not the kernel's business. */
static void consider_teleporting_damaged_player(struct P *p)
{
    struct G *g = p->g;
    int a;
    p->energy = (p->energy + 1) & 255;
    if (read_site(g, 0x409C) & 128) {             /* one time in two */
        handle_dropping(p);
        handle_teleporting(p);
        return;
    }
    a = read_rnd_byte(g, 0x40AC, 1);              /* and one in four of the rest */
    a = ((a >= 0xC0) << 7) | (a >> 1);
    if (a & g->held & 128) retrieve_object(p);    /* if its hand is empty */
    handle_dropping(p);
}

/* get_tile_and_check_for_tertiary_objects (&1715) at (tx, ty) in the mode set */
static void look_at_tile(struct P *p, int tx, int ty)
{
    struct G *g = p->g;
    int v = g->world[(ty << 8) + tx];
    p->tileX = tx; p->tileY = ty;
    g->lastTile = v & 0x3F;
    tile_effect(p, v & 0x3F, v & 0xC0);
}

/* accelerate_all_objects_within_angle (&343c): every object in sight within
   accPower (in &20 fractions) is pushed from (or, with accSign, towards) this
   one, the lighter and nearer the harder, and hurt by it when accDmg says */
static void accelerate_all(struct P *p, int range)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int centre = p->angleB5, x, a, c, w, st, ang;
    for (x = 15; x >= 0; x--) {
        if (x == p->slot) continue;
        if (obstruction_between(p, x, g->accPower)) continue;
        ang = p->angleB5 ^ g->accSign; p->angleB5 = ang;
        a = sub8(p, ang, centre, 0);
        if (a >= range) { a ^= 255; if (a >= range) continue; }
        w = g->tab[T_OBJFLAGS + OT(O_TYPE, x)] & 7;
        st = w == 7;
        a = add8(p, (w << 1) & 255, 8, 0);
        a = add8(p, a, p->dist, p->cy);
        a = sub8(p, a, g->accPower, p->cy); c = p->cy;
        a ^= 255;
        if (c) continue;                         /* too far for its weight */
        if ((g->accDmg & 128) && a >= 4) damage_slot(p, x, (a << 1) & 255);
        if (st) continue;
        a >>= 1;
        vec_from_mag_angle(p, a, ang);
        a = add8(p, p->vecA, OT(O_VY, x), p->rc);
        if (!p->ov) OS(O_VY, x, a);
        a = add8(p, p->vec[0], OT(O_VX, x), p->cy);
        if (!p->ov) OS(O_VX, x, a);
    }
    g->accDmg >>= 1;
    g->accPower = 0x28;
    g->accSign = 0;
}

/* update_explosion (&4f9c) */
static void update_explosion(struct P *p)
{
    struct G *g = p->g;
    int i, j, d, c;
    g->mode = 0x80;                              /* tiles with objects around it come alive */
    for (i = -1; i <= 1; i++)
        for (j = -1; j <= 1; j++) look_at_tile(p, (p->ps[0] + i) & 255, (p->ps[2] + j) & 255);
    p->pal = read_rnd_byte(g, 0x4FBD, 1) & 0x13;
    add_particles_t(p, 10, p->ps[0], p->ps[2], 0x91, 0x46, 0x16);
    d = p->tdataOff;
    if (d == 0) { p->flags |= 0x20; return; }
    d = (d - 1) & 255; p->tdataOff = d;
    if ((read_rnd_byte(g, 0x4FD0, 3) & 7) >= d) return;
    c = d >= 8;                                  /* a long explosion hurts what it throws */
    g->accDmg = (c << 7) | (g->accDmg >> 1);
    g->accPower = (d << 2) & 255;
    accelerate_all(p, 0xFF);
}

/* ---- bullets and mushroom balls ---------------------------------------------------------- */

/* move_bullet (&4434): bullets age, hitting tiles ages them faster; sprite and flips from the heading */
static void move_bullet(struct P *p)
{
    struct G *g = p->g;
    int a;
    if (p->energy) p->energy--;
    a = p->energy;
    if (a == 0) goto explode;
    if (g->tbColl & 128) {
        if (a >= 0x3E) goto explode;
        a = sub8(p, a, 0x14, 0);
        if (!p->cy) goto explode;
        p->energy = a;
    }
    p->vec[0] = p->vel[0]; p->vec[2] = p->vel[2];
    a = angle_from_vec(p);
    p->yFlip = a;
    if (a & 0x40) a ^= 255;
    p->xFlip = a;
    a = (a & 0x7F) >> 3;
    if (a >= 4) a = (a >> 1) ^ 6;
    change_sprite_base(p, a);
    return;
explode:                                         /* explode_bullet (&4425) */
    turn_into_fireball(p, 2);
    explode_with_duration(p, 2);
}

/* check_if_object_Y_damaged_by_projectiles (&1faf): the object touched, if
   it is one that projectiles can hurt, else 0xFF */
static int damaged_by_projectiles(struct P *p)
{
    long long *obj = p->g->obj;
    int y = p->touch, t;
    if (y & 128) return 0xFF;
    t = OT(O_TYPE, y);
    if (t == 0x44 || t == 0x40 || t == 0x25 || t == 0x26) return 0xFF;
    return y;
}

/* update_pistol_bullet (&441b) */
static void update_pistol_bullet(struct P *p)
{
    int y = damaged_by_projectiles(p);
    if (!(y & 128)) {
        damage_slot(p, y, 0x0A);
        play_sound(p->g, 28);
        turn_into_fireball(p, 2);
        explode_with_duration(p, 2);
        return;
    }
    move_bullet(p);
}

/* update_bullet_with_particle_trail (&46c3): explode on anything that can be
   hurt, else fly on leaving a trail */
static void update_bullet_trail(struct P *p, int dur, int dmg)
{
    struct G *g = p->g;
    int y = damaged_by_projectiles(p);
    if (!(y & 128)) {
        explode_with_duration(p, dur);
        damage_slot(p, y, dmg);
        p->vel[0] = p->vel[2] = 0;
        return;
    }
    move_bullet(p);
    add_particles_t(p, 1, p->ps[0], p->ps[2], 0x20, 0x01, 0x2C);
}

/* consider_moving_towards_player (&467a): homing, no gravity, damped out of water */
static void moving_towards_player(struct P *p)
{
    struct G *g = p->g;
    update_path(p);
    move_towards(p, 0x40, 8, 0x40);
    p->acc[2] = (p->acc[2] - 1) & 255;
    if (!(g->inWater & 128)) {
        p->vel[0] = seven_eighths(seven_eighths(p->vel[0]));
        p->vel[2] = seven_eighths(seven_eighths(p->vel[2]));
    }
}

/* add_to_player_mushroom_timer (&4005): the player is drugged (red or blue) for
   a while longer, and unless immune cannot move (red) or thrust (blue) for as
   long; c is the carry the caller arrives with */
static void add_mushroom_timer(struct P *p, int blue, int c)
{
    struct G *g = p->g;
    int t = blue ? g->blueMush : g->redMush, im = blue ? g->tImmob : g->immob, a, co;
    a = (0x3F + t + c) & 255; co = (0x3F + t + c) >> 8;
    if (!co) { if (blue) g->blueMush = a; else g->redMush = a; }
    if (!(g->immunity & 128) && a >= im) { if (blue) g->tImmob = a; else g->immob = a; }
}

/* play_sound_for_mushrooms (&3ff0), Y = the player's slot if the player is involved */
static void mushroom_effect(struct P *p, int blue, int isPlayer)
{
    if (isPlayer) add_mushroom_timer(p, blue, 0);
    play_sound(p->g, 15);                             /* &3ff9, and it leaves the carry set */
    particle_from_object(p, 1, 0x88, 0x47, 0x4D);
}

/* update_mushroom_ball (&4698) */
static void update_mushroom_ball(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y = p->touch;
    if (!(y & 128)) {
        if (OT(O_TYPE, y) == 0x37) { change_type(p, 0x58); return; }   /* fireballs make coronium of them */
    } else {
        if (p->energy) p->energy--;
        if (p->energy) return;
    }
    if (read_rnd_byte(g, 0x46AB, 2) & 128) return;                     /* 1 in 2: burst */
    mushroom_effect(p, p->pal & 1, p->touch == 0);
    add_particles_t(p, 32, p->ps[0], p->ps[2], 0x88, 0x47, 0x4D);
    p->flags |= 0x20;
}

/* ---- imps (&44ef) ------------------------------------------------------------------------ */

static void update_imp(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int a, c, x, wasFed, spr, flipQ;
    if (p->flags & 4) p->state = 0x80;           /* newly spawned imps start in mood minus two */
    a = ((p->state << 1) ^ p->state) & 255;
    g->walkSpd = (a & 128) ? 0x28 : 0x10;        /* slower in mood zero */
    x = (p->type - 0x29) & 255;                  /* the stimuli type */
    wasFed = p->state & 0x10;
    if (g->lastTile == 0x0A) {                   /* at a pipe: home, and where a fed imp leaves its gift */
        g->walkSpd >>= 2;
        get_this_object_centre(p);
        if (inv_neg(p->cenf[0]) >= 0x68 && (g->cYF & 128)) {
            if (wasFed) {
                g->gifts[x] = (g->gifts[x] - 1) & 255;
                if (!(g->gifts[x] & 128)) {
                    a = g->tab[T_IMPGIFT + x];
                    create_projectile(p, a, 0xC8, a);
                }
            }
            p->removal |= 0x80;                  /* set_object_as_far_away */
            return;
        }
    }
    give_min_energy(p, g->tab[T_IMPEN + x]);
    check_for_npc_stimuli(p, x);
    if (wasFed) c = 1;
    else { c = p->stimuli & 1; p->stimuli >>= 1; }
    if (c) p->state = (p->state & 0x3F) | 0x90;  /* fed: mood minus two, and remembers it */
    update_path(p);
    update_walking_npc_and_check(p, 2);
    if (p->touch == p->target && !(p->state & 128) && !(touching_angle(p) & 128)) {
        damage_slot(p, p->touch, 5);             /* imps bite */
        p->vel[0] = OT(O_VX, p->touch); p->vel[2] = OT(O_VY, p->touch);
        goto at_target;
    }
    a = p->state & 15;
    if (a >= 10) {
        if (g->inWater & 128) { spr = 0x69; flipQ = 1; goto set_sprite; }   /* jumping, not in water */
        if ((read_site(g, 0x45B7) & 0x1F) == 0) set_npc_jumping(p);        /* in water: 1 in 32 */
    } else {
        if (a == 0) {
            a = inv_neg(p->tileAng);
            p->state &= 0xDF;
            if (a >= 0x28) p->state |= 0x20;     /* climbing */
        }
        if (p->state & 0x20) { set_npc_facing_tile_collision(p); goto at_target; }
    }
    if (p->touch == p->target) goto at_target;
    find_and_fire(p, 8, g->tab[T_IMPPROJ + p->npcType], 0, 0);
    spr = 0x64; flipQ = 0;
    if (p->vel[0] != 0) { a = sprite_offset(p, 0x0C, 2); spr = (0x64 + (a >> 2)) & 255; flipQ = 1; }
    goto set_sprite;
at_target:
    a = sprite_offset(p, 0x0C, 2);
    spr = (0x67 + ((a >> 2) & 1)) & 255; flipQ = 0;
set_sprite:
    if (flipQ) consider_flipping(p, 3);
    change_sprite(p, spr);
    if (!(p->flags & 8) && p->fc16 == 0) read_site(g, 0x45FB);   /* a 1 in 2 chance of a call, a sound */
}

/* ---- fluffy (&4288) ---------------------------------------------------------------------- */

static void update_fluffy(struct P *p)
{
    struct G *g = p->g;
    int a, c, x, path = 0;                       /* 0 just animate, 1 squeal, 2 maybe purr */
    give_min_energy(p, 0x29);
    check_for_npc_stimuli(p, 6);
    update_path(p);
    if ((p->flags & 8) == 8) path = 1;           /* hurt: squeal */
    else {
        a = p->state & 0xC0;
        if (a == 0x80) path = 1;                 /* miserable: squeal */
        else {
            if (a < 0x80) p->target = p->slot;   /* content: seek nothing */
            if ((p->fc & 0x0B) == 0) {           /* every eight frames, any enemies about? */
                x = find_or_count(p, 0x2A, 0x86, 0, 1);
                path = 2;
                if (!(x & 128) && p->nearestDist < read_rnd_byte(g, 0x42BA, 1)) path = 1;
            }
        }
    }
    if (path == 1) { play_sound(g, 19); p->timer = 0x80 | (p->timer >> 1); }   /* the squeal leaves the carry set: active */
    else if (path == 2) {
        a = p->state;
        if (!(a & 128)) a = neg8(a);
        c = a >= read_rnd_byte(g, 0x42CE, 1);
        p->timer = (c << 7) | (p->timer >> 1);            /* active more when happy or unhappy */
        if (c) play_sound(g, 20);                         /* and then it purrs */
    }
    /* consider_animating_fluffy: while active, flip one way or the other at random, then wander */
    x = read_rnd_byte(g, 0x42DB, 1) & 2;
    a = p->timer ^ (x ? p->yFlip : p->xFlip);
    if (x) p->yFlip = a; else p->xFlip = a;
    if (!(a & p->timer & 128)) return;
    if (g->held == p->slot) return;
    g->walkSpd = 0x28;
    update_walking_npc_and_check(p, 2);
}

/* animate_sprite_from_timer (&44dc): the first sprite, or while the timer
   runs the second and third by turns (frogmen kicking, worms wriggling) */
static void animate_from_timer(struct P *p)
{
    int a = 0, c = 0;
    if (p->timer != 0) {
        p->timer--;
        if (p->timer != 0) { a = (p->timer >> 2) & 1; c = 1; }
    }
    change_sprite_base(p, a + c);
}

/* ---- frogmen (&4463) --------------------------------------------------------------------- */

static void update_frogman(struct P *p, int kind)      /* 0 red, 1 green, 2 invisible */
{
    struct G *g = p->g;
    int a, c, x, minE;
    if (kind == 0) {
        check_for_npc_stimuli(p, 9);
        avoid_type(p, 0x33);                     /* red mushroom balls */
        update_path(p);
        minE = 0x64;
    } else {
        c = 1;                                   /* the dispatch's CPY #0 leaves the carry set */
        if (kind == 2) { c = p->visibility & 1; p->visibility >>= 1; }
        if (p->touch == 0) {                     /* a kick: drugs the player as red mushrooms do, and hurts */
            add_mushroom_timer(p, 0, c);
            p->timer = 7;
            damage_slot(p, 0, 14);
        }
        minE = 0x5A;
    }
    give_min_energy(p, minE);
    g->walkSpd = 0x14;
    g->relTY = sub8(p, p->ty, p->ps[2], 0);      /* update_walking_npc, without the obstacle check */
    g->relTX = sub8(p, p->tx, p->ps[0], 1);
    walk_npc(p, 1, g->tab[T_WALKMAXACC + 1], g->tab[T_WALKWEIGHT + 1]);
    consider_flipping(p, 3);
    x = 4;
    if (p->state & 15) {                         /* not on a surface it can walk on: jump only in water, every 16 frames */
        if ((g->inWater & 128) || p->fc16 != 0) goto animate;
    } else if (inv_neg(p->tileAng) >= 0x28) { set_npc_facing_tile_collision(p); x = 0xFF; }
    if (p->timer != 0) goto animate;             /* jumped or kicked lately */
    a = 9;
    if (!(p->objCY & 128)) {                     /* nothing underneath but tiles: mostly small hops */
        int r = read_rnd_byte(g, 0x44C5, 2);
        a = g->walkSpd >> 2; c = (g->walkSpd >> 1) & 1;
        if (r >= 0x20) goto with_x;
        if (r < 0x0A) a = add8(p, a, 5, c);
    }
    x = a;
with_x:
    p->timer = a;
    if (x & 128) goto animate;
    set_npc_jumping_speed(p, (x << 2) & 255);
animate:
    animate_from_timer(p);
}

/* ---- energy and burrowing ---------------------------------------------------------------- */

/* increase_energy_by_one_if_not_zero (&254e) */
static void energy_up_if_not_zero(struct P *p)
{
    if (p->energy == 0) return;
    p->energy = (p->energy + 1) & 255;
    if (p->energy == 0) p->energy = 255;
}

/* gain_energy_Y_and_flash_if_damaged (&353a): heal slowly, and while weak show
   the damaged palette two frames in eight */
/* flash_if_damaged (&3547): the minimum energy, and the damaged palette two frames in eight while weak; 1 if strong */
static int flash_if_damaged(struct P *p, int y)
{
    struct G *g = p->g;
    int a = give_min_energy(p, y), strong = a >> 7, c = strong;
    if (!c) c = (p->fc & 7) >= 2;
    p->pal = g->tab[T_OBJPAL + p->type] & 0x7F;
    if (!c) p->pal ^= 0x30;
    return strong;
}

static int gain_energy_and_flash(struct P *p, int y)
{
    struct G *g = p->g;
    if (g->frm % 4 == 0 && p->energy < 0xC0) energy_up_if_not_zero(p);
    return flash_if_damaged(p, y);
}

/* consider_npc_burrowing (&2a02): a creature that wants to dig and is on a
   surface creeps into it; one inside the tiles crawls on and now and then is
   gone.  1 if burrowing or gone */
static int consider_burrowing(struct P *p)
{
    struct G *g = p->g;
    int xi;
    if (g->surr & 128) {
        if ((read_site(g, 0x2A06) & 255) != 0) goto creep;
        p->removal |= 0x80;
        return 1;
    }
    if (!(g->tbColl & p->state & 128)) return 0;
    play_sound(g, 7);                            /* &2a17, this way in only */
creep:
    p->acc[2] = (p->acc[2] - 1) & 255;
    for (xi = 2; xi >= 0; xi -= 2) p->vel[xi] = (get_sign(p->pvel[xi]) << 1) & 255;
    set_position_from_previous(p);
    for (xi = 2; xi >= 0; xi -= 2) add_to_pos(p, xi, p->vel[xi], p->vel[xi] & 128);
    return 1;
}

/* ---- worms and maggots (&4e5e) ----------------------------------------------------------- */

static void update_worm_or_maggot(struct P *p, int ta, int ty, int dmg)
{
    struct G *g = p->g;
    int r, c;
    consider_finding_target(p, ta, ty);
    update_path(p);
    if (consider_burrowing(p)) { c = p->cy; goto animate; }
    r = read_site(g, 0x4E6C) & 255;
    if (!(g->inWater & 128)) r = 0xFF;            /* under water they always want to dig */
    if ((r & 15) == 0) play_sound(g, 45);
    c = r >= 0xF6;
    p->state = (c << 7) | (p->state & 0x7F);      /* the wish to burrow */
    if (p->touch == p->target) { p->timer = 0x0A; damage_slot(p, p->touch, dmg); }
    if (((p->waterline - 1) & 255) < 128) {       /* at the waterline: every 16 frames pretend something is underneath, to jump off it */
        int f = g->frm & 15, n = 0, i;
        for (i = 0; i < 4; i++) n += (f >> i) & 1;
        p->objCY = f == 0 ? 0xFF : n - 1;
    }
    g->walkSpd = 0x10;
    if (p->tflags & 128) {                        /* has seen its target: twice as fast, and a squeal when near the middle of the screen */
        g->walkSpd = 0x20;
        {
            int d = distance_from_screen_centre(p, p->slot);
            if (d < 0x0F && (d ^ 0x0F) >= read_rnd_byte(g, 0x4EA5, 2)) {
                play_sound(g, 45); play_sound(g, 46);
            }
        }
    }
    c = update_walking_npc_and_check(p, 6);
    if (!c) p->timer = 6;
animate:
    consider_flipping(p, 3);
    p->yFlip = sub8(p, p->vel[2], 4, c);          /* flipped over when moving up */
    p->timer |= (p->fc & 4) >> 1;                 /* a wriggle four frames in eight */
    animate_from_timer(p);
}

static void update_worm(struct P *p)
{
    update_worm_or_maggot(p, 0x86, 0x07, 0);      /* wary of red frogmen, green frogmen and the player */
    p->tflags |= 0x20;
}

static void update_maggot(struct P *p)
{
    p->energy &= 0x7F;
    update_worm_or_maggot(p, 0x82, 0x2F, 0x14);   /* after crew members, the player and white birds; bites */
}

/* ---- slimes (&422a, &4266, &47c9) and red drops (&4799) ---------------------------------- */

static void update_green_slime(struct P *p)
{
    struct G *g = p->g;
    int a, c;
    consider_flipping(p, 3);
    check_for_npc_stimuli(p, 8);
    update_path(p);
    consider_burrowing(p);
    c = p->stimuli & 1; p->stimuli >>= 1;
    if (c) { play_sound(g, 18); change_type(p, 0x0B); return; }   /* fed a coronium crystal: yellow */
    g->walkSpd = 0x0C;
    update_walking_npc_and_check(p, 3);
    if ((p->state & 15) >= 10) p->timer = 0x0F;   /* a boulder while jumping */
    a = sprite_offset(p, 0x11, 3);
    a = sub8(p, a, 8, p->cy);                     /* the offset routine leaves the carry its last add set (its note says clear) */
    change_sprite_base(p, inv_neg(a) >> 1);
}

static void update_yellow_slime(struct P *p)
{
    struct G *g = p->g;
    int a, x;
    if (p->touch == 0) p->timer = 0;              /* the player's touch keeps it yellow */
    if (read_rnd_byte(g, 0x426A, 1) & g->tbColl & 128) {
        p->timer = (p->timer + 1) & 255;
        if (p->timer == 0) { change_type(p, 0x0A); return; }
    }
    x = 0x3C;
    a = (read_rnd_byte(g, 0x427A, 3) >> 1) | 0x80;
    if (a < p->timer) x = 0x39;                   /* flashes green more as it wakes */
    p->pal = x;
}

/* change_object_sprite_to_A without the height half: the red slime keeps its top */
static void set_sprite_x_only(struct P *p, int a)
{
    int d, c;
    p->spr = a;
    d = sub8(p, p->siz[0], p->g->tab[T_SPRW + a], 1); c = p->cy;
    d = ((c << 7) | (d >> 1)) ^ 128;
    add_to_pos(p, 0, d, d & 128);
}

static void update_red_slime(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int a, y;
    if (p->fc16 == 0) {
        if (read_rnd_byte(g, 0x47D7, 1) & 128) {  /* every sixteen frames, 1 in 2: a drop */
            y = create_new_object(p, 0x36, 4);
            if (y >= 0) {
                OS(O_XF, y, (p->xFlip & 128) ? 0x90 : 0x30);
                OS(O_YF, y, 0x40);
                OS(O_VY, y, 4);
            }
        }
        a = 3;
    } else {
        a = sub8(p, p->fc16 >> 1, 4, 1);
        if (a & 128) a ^= 255;
    }
    set_sprite_x_only(p, (a + 0x1C) & 255);
}

static void update_red_drop(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y = p->touch, t;
    if (!(y & 128)) {
        t = OT(O_TYPE, y);
        if (t == 0x09) return;                    /* its own slime */
        if (t == 0x0B) { OS(O_TYPE, y, 0x55); return; }   /* a yellow slime becomes a coronium boulder */
        if (t != 0x10) { damage_slot(p, y, 0x64); play_sound(g, 31); }   /* piranhas are proof against it */
    } else if (!(g->tbColl & 128)) return;
    explode_with_duration(p, 0);
}

/* ---- piranhas and wasps (&4f21) ---------------------------------------------------------- */

static void update_piranha_or_wasp(struct P *p)
{
    struct G *g = p->g;
    int a, c, r, x;
    a = 5;                                        /* wasps call large hives home */
    c = p->type == 0x11;
    p->yFlip = (c << 7) | (p->yFlip >> 1);
    if (!(p->yFlip & 128)) { p->acc[2] = 4; a = 4; }     /* piranhas sink, and call small hives home */
    p->acc[2] = (p->acc[2] - 1) & 255;
    if (!(read_rnd_byte(g, 0x4F33, 2) & 0x40)) {
        if (p->state < read_rnd_byte(g, 0x4F39, 1)) a = 0;   /* the more aggressive, the more often the player */
        consider_finding_target(p, a, p->type);
    }
    update_path(p);
    r = read_site(g, 0x4F45) & 255;
    if (r != 0 && r >= p->state && p->touch == 0) { damage_slot(p, 0, 0x18); play_sound(g, 47); }
    change_sprite_base(p, sprite_offset(p, 0x0C, 3) >> 2);
    if (p->vel[0] != 0) p->xFlip = p->vel[0];
    if (!(g->tbColl & 128) && ((p->yFlip ^ g->inWater) & 128)) return;   /* out of its element */
    move_towards(p, 0x30, 0x18, 0x28);
    if (g->frm % 8 != 0) return;
    r = read_site(g, 0x4F82);
    x = r & 2;
    a = read_rnd_byte(g, 0x4F88, 2) & 0x1F;
    a = sub8(p, a, 0x10, (r >> 8) & 1);
    p->acc[x] = add8(p, a, p->acc[x], p->cy);
    if (p->energy < 0x0A) energy_up_if_not_zero(p);
}

/* ---- rolling robots and turrets (&4ed8) --------------------------------------------------- */

/* consider_firing (&4ef9) and set_turret_or_robot_energy (&4f10): projectiles
   of type x at things that shoot (the lab's turret also at things that fly)
   while strong; heal, and flash when weak */
static void robot_fire_and_energy(struct P *p, int x, int fire)
{
    struct G *g = p->g;
    int y;
    if (fire && (p->energy & 128)) {
        y = 0x84;
        if (p->ps[2] < 0xB4 && !(read_rnd_byte(g, 0x4F05, 2) & 0x40)) y = 0x86;
        find_and_fire(p, p->energy >> 1, x, 0x81, y);
    }
    gain_energy_and_flash(p, g->tab[T_ROBOTMINE + (p->type - 0x1C)]);
}

static void update_rolling_robot(struct P *p)
{
    struct G *g = p->g;
    int t = p->type;
    if (t != 0x1E && !(p->energy & 128)) { robot_fire_and_energy(p, 0, 0); return; }   /* magenta and red ones sit still when weak */
    check_for_npc_stimuli(p, 5);
    update_path(p);
    g->walkSpd = 0x18;
    update_walking_npc_and_check(p, 4);
    consider_flipping(p, 3);
    robot_fire_and_energy(p, g->tab[T_ROBOTBULLET + (t - 0x1C)], 1);
}

/* update_turret (&4ed8): its tertiary data holds the projectile type, and whether it is switched off */
static void update_turret(struct P *p)
{
    int a = p->data;
    if (a & 1) { robot_fire_and_energy(p, 0, 0); return; }
    robot_fire_and_energy(p, a >> 1, 1);
}

/* ---- hovering ------------------------------------------------------------------------------ */

static void apply_acceleration(struct P *p);

/* add_jetpack_thrust_particles (&1f3d): a particle behind anything accelerating */
static void jetpack_particles(struct P *p)
{
    if ((p->acc[0] | p->acc[2]) == 0) return;
    add_particles_t(p, 1, p->ps[0], p->ps[2], 0x86, 0x01, 0x0B);
}

/* consider_hovering_over_ground (&3a1e): every four frames, lift off the ground below */
static void hover_over_ground(struct P *p)
{
    struct G *g = p->g;
    int a, c, mh, space, xf, r;
    if (g->frm % 4 != 0) return;
    mh = ((p->siz[2] ^ 255) & 255) >> 1;
    a = p->siz[0] >> 1; c = p->siz[0] & 1;       /* check_for_space_below_object: the middle, the bottom */
    xf = add8(p, a, p->pf[0], c); c = p->cy;
    p->tileX = add8(p, p->ps[0], 0, c);
    p->tileY = p->mxp[2];
    space = space_at_position(p, xf, p->mxf[2]);
    if (space == 0xFF) p->acc[2] = (p->acc[2] - 1) & 255;
    else {
        if (space >= mh) return;
        r = read_site(g, 0x3A34);
        a = ((r & 255) | 0xC0) + space + ((r >> 8) & 1);
        p->acc[2] = (p->acc[2] - (a >= 256 ? 2 : 3)) & 255;
    }
    p->vel[2] = seven_eighths(p->vel[2]);
}

/* thrust_towards_target (&487a): flying creatures' movement */
static void thrust_towards_target(struct P *p)
{
    move_towards(p, 0x1C, 4, 0x80);
    p->acc[2] = (p->acc[2] - 1) & 255;
    hover_over_ground(p);
    jetpack_particles(p);
}

/* move_hovering_npc (&486e): after the player */
static void move_hovering_npc(struct P *p)
{
    p->target = 0;
    update_path(p);
    consider_flipping(p, 7);
    thrust_towards_target(p);
}

/* update_hovering_ball (&43e7) and the invisible kind (&43eb) */
static void update_hovering_ball(struct P *p, int invisible)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y = p->touch;
    if (!invisible) p->pal = g->tab[T_TRANSPAL + ((p->fc >> 2) & 3)];
    if (!(y & 128) && OT(O_TYPE, y) != p->type) { damage_slot(p, y, 3); play_sound(g, 26); }
    p->energy &= 4;
    p->timer = (p->timer - 1) & 255;
    if (p->timer == 0) { play_sound(g, 27); p->removal |= 0x80; return; }   /* back to its nest */
    move_hovering_npc(p);
    thrust_towards_target(p);                    /* twice as fast as other flying things */
}

/* ---- fireballs (&4ad6) --------------------------------------------------------------------- */

/* remove_plasma_ball_or_fireball (&4ac8): a burst of plasma particles, then gone */
static void remove_plasma_or_fireball(struct P *p)
{
    add_particles_t(p, 0x1E, p->ps[0], p->ps[2], 0x91, 0x02, 0x00);
    p->flags |= 0x20;
}

/* consider_fireball_damage_and_animate (&4ae8) */
static void fireball_damage_and_animate(struct P *p, int dmg)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y = p->touch, r, t;
    if (p->fc16 == 0 && p->timer >= 8) dmg = 0x5A;        /* a big burn at the start of a long one */
    if (!(y & 128)) {
        if (y == 0 && (g->fireImm & 128)) dmg = 0;
        damage_slot(p, y, dmg);
        t = OT(O_TYPE, y);                       /* and it follows what it burns, unless that cannot collide */
        if (range_of_type(g, t) != 4 && t != 0x40 && t != 0x44 && t != 0x37) { p->vel[0] = OT(O_VX, y); p->vel[2] = OT(O_VY, y); }
    }
    r = read_site(g, 0x4B0B) & 255;
    p->xFlip = r; p->yFlip = (r << 1) & 255;
    p->pal = g->tab[T_FIREPAL + (p->timer & 7)];
    p->angleB5 = 0xC0;
    add_particles_t(p, 1, p->ps[0], p->ps[2], 0x81, 0x02, 0x21);
}

static void set_position_from_previous_except_yf(struct P *p)
{
    p->ps[2] = p->qps[2]; p->pf[0] = p->qpf[0]; p->ps[0] = p->qps[0];
}

static void update_fireball(struct P *p)
{
    struct G *g = p->g;
    int a, c;
    a = p->waterline & read_rnd_byte(g, 0x4AD8, 2);
    a &= read_rnd_byte(g, 0x4ADA, 1);
    if (a & 128) { remove_plasma_or_fireball(p); return; }   /* under water it goes out */
    if (p->target != 0) {                        /* update_permanent_fireball: a nest's, flickering up and down */
        set_position_from_previous_except_yf(p);
        if (!(read_rnd_byte(g, 0x4B4D, 1) & 128)) { p->vel[0] = p->vel[2] = 0; set_position_from_previous(p); return; }
        a = read_rnd_byte(g, 0x4B51, 1) & 0x0F;
        a = add8(p, a, p->fc16, 1);
        c = a >> 7; a = (a << 1) & 255;
        a = add8(p, a, p->pf[2], c);
        a = add8(p, a, 0x18, p->cy);
        p->pf[2] = a;
        p->timer = (p->timer - 1) & 255;
        fireball_damage_and_animate(p, 0x14);
        return;
    }
    p->timer = (p->timer - 1) & 255;             /* update_temporary_fireball: burns out */
    if (p->timer & 128) { p->flags |= 0x20; return; }
    fireball_damage_and_animate(p, 0x0A);
}

static void update_moving_fireball(struct P *p)
{
    struct G *g = p->g;
    int a = 0;
    fireball_damage_and_animate(p, 4);
    set_position_from_previous(p);
    if (p->touch != 0) { p->vel[0] = p->pvel[0]; p->vel[2] = p->pvel[2]; a = p->pvel[2]; }
    consider_finding_target(p, a, 0);            /* move_fireball (&4672), with whatever A held */
    avoid_fireballs(p);
    moving_towards_player(p);
    if (!(g->inWater & 128)) {
        p->acc[2] = 0xFC;                        /* up and out of the water */
        if (p->waterline & 128) { remove_plasma_or_fireball(p); return; }
    }
    apply_acceleration(p);
    add_to_pos(p, 2, p->vel[2], p->vel[2] & 128);
    add_to_pos(p, 0, p->vel[0], p->vel[0] & 128);
}

static int far_away(struct P *p, int y);   /* &111d, defined with the viewport below */

/* ---- promotion (&0be8) -------------------------------------------------------------------- */

/* promote_secondary_object_to_primary_if_Y_slots_free (&0c15): secondary x is
   brought back as a primary object, with the quarter-tile position and the
   coarse energy that were kept for it */
static void promote_secondary(struct P *p, int x, int slots)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y, a;
    if ((int)g->game[G_SECY0 + x] == 0) return;
    y = create_new_object(p, (int)g->game[G_SECT0 + x], slots);
    if (y < 0) return;
    OS(O_X, y, (int)g->game[G_SECX0 + x]);
    OS(O_Y, y, (int)g->game[G_SECY0 + x]);
    a = (int)g->game[G_SECE0 + x];
    OS(O_ENERGY, y, a | 0x0F);
    a = (a << 4) & 255;
    OS(O_XF, y, a & 0xC0);
    OS(O_YF, y, (a << 2) & 255);
    g->game[G_SECY0 + x] = 0;
}

static void consider_promoting(struct P *p)
{
    struct G *g = p->g;
    int a, c, x, saveX, saveY;
    if (!(g->secMode & 128)) {                    /* the usual case: one of them, in a shuffled order */
        a = inv_neg(p->vel[2]);
        c = inv_neg(p->vel[0]);
        if (c > a) a = c;                         /* how fast the player is moving */
        c = (a >> 1) & 1;                         /* the second shift leaves bit 1 in the carry */
        a = add8(p, a >> 2, g->secDist, c);       /* and the add that follows takes it */
        g->secDist = a;
        if (!p->cy) {                             /* until that adds up to a screenful */
            g->secNext = (g->secNext - 1) & 255;
            if (g->secNext & 128) {
                g->secShuf = read_site(g, 0x0BFF) & 0x1F;
                g->secNext = 0x1F;
            }
            promote_secondary(p, g->secNext ^ g->secShuf, 4);
            return;
        }
    }
    saveX = p->ps[0]; saveY = p->ps[2];           /* all of them, against the new view */
    for (x = 0x1F; x >= 0; x--) {
        p->ps[2] = (int)g->game[G_SECY0 + x];
        p->ps[0] = (int)g->game[G_SECX0 + x];
        if (far_away(p, 4)) continue;
        promote_secondary(p, x, 1);
    }
    p->ps[0] = saveX; p->ps[2] = saveY;
}

/* ---- the viewport (&152a, &161f, &3684) --------------------------------------------------- */

/* divide_by_eight (&3275): three halvings that keep the sign, leaving the last
   bit shifted out in the carry, which the caller adds in */
static int div8_signed(struct P *p, int a)
{
    int i, c = 0, b7;
    for (i = 0; i < 3; i++) { b7 = (a >> 7) & 1; c = a & 1; a = (b7 << 7) | (a >> 1); }
    p->cy = c;
    return a;
}

/* calculate_amount_of_scrolling_needed_in_direction (&15d2): how far the screen
   is from where the player wants it, in eighths of a tile, with the scrolling
   velocity easing towards the player's own so the view does not jerk */
static int scroll_needed(struct P *p, int xi)
{
    struct G *g = p->g;
    int a, c, cfrac, v, d;
    if (g->shipMoving & 128) {
        if (xi == 0) return 2;                   /* the ship leaves to the right */
        p->cen[2] = 0x3B;                        /* and the player's height is fixed */
    }
    cfrac = p->cenf[xi] >= g->orgF[xi];           /* this carry is wanted much later */
    a = p->vel[xi];
    if (xi != 0) a = (((a >> 7) & 1) << 7) | (a >> 1);   /* y counts for half as much */
    a = div8_signed(p, a);
    v = g->sVel[xi];
    d = sub8(p, a, v, 1);
    if (a != v) {                                 /* ease one step towards it */
        if (d & 128) v = (v - 2) & 255;
        v = (v + 1) & 255;
    }
    g->sVel[xi] = v;
    a = div8_signed(p, v); c = p->cy;
    a = add8(p, a, xi ? g->scrollY : g->scrollX, c);     /* whatever the arrow keys asked for */
    a = add8(p, a, p->cen[xi], 0);
    a = sub8(p, a, g->org[xi], cfrac);
    a = sub8(p, a, g->tab[T_SCRCENTRE + xi], 1);
    d = sub8(p, a, g->secs[xi], 1);
    if (d & 128) a = add8(p, a, 1, 0);
    return a;
}

/* update_screen_variables (&161f): move the origin by the sections decided, and
   work out where sprites are to be drawn from.  Only the parts the physics can
   see are here; the screen addressing is the plotter's business */
static void update_screen_variables(struct P *p)
{
    struct G *g = p->g;
    int xi, a, c, y, n = 0;
    for (xi = 2; xi >= 0; xi -= 2)
        if (g->secs[xi] != 0 && g->orgF[xi] == 0) n = 0xFF;
    g->newTiles = n;                              /* a tile-aligned edge uncovers new tiles */
    for (xi = 2; xi >= 0; xi -= 2) {
        c = (g->secs[xi] >> 7) & 1;
        a = (g->secs[xi] << 1) & 255;
        y = c ? 0xFF : 0;
        if (xi >= 2) a = (a << 1) & 255;          /* a section is &40 of a tile down, &20 across */
        a = (a << 4) & 255;
        g->frac[xi] = a;
        a = add8(p, a, g->orgF[xi], 0);
        g->orgF[xi] = a;
        g->sgn[xi] = y;
        g->org[xi] = add8(p, y, g->org[xi], p->cy);
    }
    for (xi = 2; xi >= 0; xi -= 2) {
        int offF, off;
        offF = sub8(p, 0, g->frac[xi], 1);
        off = sub8(p, 0, g->sgn[xi], p->cy);
        if (off & 128) { off = 0; offF = 0; }     /* nothing to offset when scrolling right or down */
        a = g->orgF[xi];
        g->scr[2 + xi] = a;
        a = add8(p, a, offF, 0);
        g->scr[3 + xi] = a;
        c = p->cy;
        g->scr[6 + xi] = g->org[xi];
        g->scr[7 + xi] = add8(p, g->org[xi], off, c);
    }
    g->scr[0] = g->org[0];
    g->scr[1] = g->org[2];
}

/* prepare_screen_for_scrolling (&3684), less the wiping: the strip of tiles the
   scroll has uncovered is looked at, and a tile that makes an object makes it now */
static void prepare_screen(struct P *p)
{
    struct G *g = p->g;
    int tx, ty, n, i, fi, y;
    if (g->secs[0] != 0) {                        /* a vertical edge, four tiles down it */
        y = (g->sgn[0] + 1) & 255;
        add8(p, g->tab[T_SCROFFXF + y], g->orgF[0], 0);
        tx = add8(p, g->tab[T_SCROFFX + y], g->org[0], p->cy);
        ty = g->org[2];
        n = 4; fi = 2;
    } else if (g->secs[2] != 0) {                 /* a horizontal edge, eight along it */
        y = (g->sgn[2] + 1) & 255;
        add8(p, g->tab[T_SCROFFYF + y], g->orgF[2], 0);
        ty = add8(p, g->tab[T_SCROFFY + y], g->org[2], p->cy);
        tx = g->org[0];
        n = 8; fi = 0;
    } else return;
    if (g->orgF[fi] != 0) n++;                    /* one more if the edge is not tile aligned */
    g->mode = g->newTiles & 0x80;
    for (i = 0; i < n; i++) {
        look_at_tile(p, tx, ty);
        if (fi == 0) tx = (tx + 1) & 255; else ty = (ty + 1) & 255;
    }
}

/* redraw_screen (&158e): the view has moved too far to scroll, so it is rebuilt
   from the bottom up, four tiles at a time, and every tile of it is looked at */
static void redraw_screen(struct P *p)
{
    struct G *g = p->g;
    int i;
    g->orgF[0] = 0x80; g->orgF[2] = 0x80;
    g->org[2] = sub8(p, p->cen[2], 1, 1);
    g->org[0] = sub8(p, p->cen[0], 4, p->cy);
    g->secs[2] = 0xFE; g->secs[0] = 0;
    update_screen_variables(p);
    g->org[2] = add8(p, g->org[2], 4, 0);
    for (i = 0; i < 8; i++) {
        update_screen_variables(p);
        prepare_screen(p);
    }
    g->secs[2] = 0;
    g->secMode = 0xF0;                            /* and every secondary object is reconsidered */
}

/* consider_how_to_scroll_screen (&152a): how far to scroll, or a redraw if the
   view has moved too far to catch up by scrolling */
static void consider_how_to_scroll(struct P *p)
{
    struct G *g = p->g;
    int a, absx, absy, yv, s;
    g->secMode >>= 1;
    get_this_object_centre(p);
    a = scroll_needed(p, 0);
    absx = inv_neg(a);
    if (absx >= 0x0C) { redraw_screen(p); return; }
    if (absx >= 2) {
        s = 2;
        if (absx > 2 && (g->orgF[0] & 0x7F) == 0) s = 4;      /* aligned to half a tile: go faster */
        else if ((g->orgF[0] & 0x20) != 0) s = 1;
    } else s = absx;
    if (a & 128) s = neg8(s);
    g->secs[0] = s;
    yv = scroll_needed(p, 2);
    absy = inv_neg(yv);
    if (absy < absx) { g->secs[2] = 0; return; }              /* x wants it more */
    if (absy >= 0x0C) { redraw_screen(p); return; }
    if (absy < 2) s = yv;
    else {
        s = (g->orgF[2] & 0x40) ? 1 : 2;
        if (yv & 128) s = neg8(s);
    }
    g->secs[2] = s;
    g->secs[0] = 0;
}

/* ---- the tiles' own routines (&3e1b-&3fd2) ------------------------------------------------ */

/* the tail of create_primary_object_from_tertiary (&4059): the new object y
   of type t sits on the tile, flipped as the tile is, and knows its tertiary data */
static void finish_from_tertiary(struct P *p, int y, int type, int bd, int flp)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int spr = g->tab[T_OBJSPRITE + type];
    OS(O_X, y, p->tileX); OS(O_TX, y, p->tileX); OS(O_Y, y, p->tileY); OS(O_TY, y, p->tileY);
    OS(O_FLAGS, y, (flp | 5) & 255);
    OS(O_XF, y, (flp & 0x80) ? (g->tab[T_SPRW + spr] ^ 255) : 0);
    OS(O_YF, y, (flp & 0x40) ? 0 : (g->tab[T_SPRH + spr] ^ 255));
    OS(O_TDATA, y, bd);
    g->tert[bd] &= 0x7F;                         /* now a primary object */
}

/* create_primary_object_from_tertiary (&4042): unless it is already about;
   the slot, or -1, on which the tile routine gives up */
static int create_from_tertiary(struct P *p, int type, int ySlots, int bd, int flp)
{
    struct G *g = p->g;
    int y;
    if (bd != 0 && !(g->tert[bd] & 128)) return -1;
    y = create_new_object(p, type, ySlots);
#ifdef HOST_DEBUG
    printf("  create from tertiary: type %02x at %02x,%02x data off %02x -> slot %d" "\n", type, p->tileX, p->tileY, bd, y);
    fflush(stdout);
#endif
    if (y < 0) return -1;
    finish_from_tertiary(p, y, type, bd, flp);
    return y;
}

static int spawn_from_nest(struct P *p, int bd, int be, int slots, int flp);

/* spawn_object (&3e4f): one of the nest's creatures, if it has any left and is
   active and there is room; the slot, or -1.  Leaves the new object's x fraction
   in p->vecA, as the 6502 leaves it in A */
static int spawn_from_nest(struct P *p, int bd, int be, int slots, int flp)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int d = g->tert[bd], a = (d << 1) & 255, type, y, spr, xf;
    if (a < 8) return -1;                        /* nothing left in it */
    if (a & 6) return -1;                        /* not active */
    type = g->tab[T_TERTTYPE + be];
    y = create_new_object(p, type, slots);
    if (y < 0) return -1;
    finish_from_tertiary(p, y, type, bd, flp);
    g->tert[bd] = sub8(p, d, 3, 0);              /* one fewer; the top bit stays, it is still a nest */
    OS(O_FLAGS, y, 5);
    spr = g->tab[T_OBJSPRITE + type];
    xf = (g->tab[T_SPRW + spr] ^ 255) >> 1;      /* centred on the nest */
    OS(O_XF, y, xf);
    p->vecA = xf;
    return y;
}

/* update_nest_or_pipe_tile (&3e1b): when plotted, its bush; when plotted and
   flipped, at once, else 1 in 32 on a collision, one of its creatures */
static void tile_nest_or_pipe(struct P *p, int bd, int be, int flp)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int x = 5, m, c, d, a, type, y, spr;
    if (bd == 0) return;
    m = g->mode & 0x90;
    if (m == 0) c = (read_site(g, 0x3E48) & 255) >= 0xF7;
    else {
        if (m & 0x80) x = 0;                     /* first plotted: even if every slot is taken */
        c = flp >> 7;
        d = g->tert[bd];
        if (d & 128) {
            y = create_from_tertiary(p, 0x40, x, bd, flp);
            if (y < 0) return;
            OS(O_YF, y, 0x40); OS(O_XF, y, 0x40);
        }
    }
    if (!c) return;
    spawn_from_nest(p, bd, be, x, flp);
}

/* check_if_object_can_trigger_switches (&49c5): the object in slot y, by its
   weight, and x as the original passes it (a type, a data byte, or an offset) */
static int can_trigger_switches(struct P *p, int ySlot, int x)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int w = g->tab[T_OBJFLAGS + OT(O_TYPE, ySlot)] & 7;
    if (w < 2) return 0;
    if (x == 0x35) return 0;                     /* invisible debris */
    if (x >= 0x27) return 1;
    return x < 0x22;                             /* clawed robots and Triax do not */
}

/* process_switch_effects (&49db): set n of the table names the tertiary data
   bytes to change; the first byte touched is always data byte 0 (the set's
   leading zero is used as an offset, as in the original) */
static void process_switch_effects(struct P *p, int a, int mask)
{
    struct G *g = p->g;
    int toggle = (a >> 1) & 3, n = a >> 3, y = -1, x = 0, v;
    for (;;) { y++; if (g->tab[T_SWITCHFX + y] != 0) continue; n--; if (n < 0) break; }
    for (;;) {
        v = g->tert[x];
        g->tert[x] = (v & mask) ^ toggle;
        play_sound(g, 36);
        y++;
        x = g->tab[T_SWITCHFX + y];
        if (x == 0) break;
    }
}

/* update_invisible_switch_tile (&3ef2): an object of the right kind trips it */
static void tile_invisible_switch(struct P *p, int bd, int be)
{
    struct G *g = p->g;
    int t = g->tab[T_TERTTYPE + be], d, mask, a;
    if (!(t & 128) && t != p->type) return;
    if (!can_trigger_switches(p, p->slot, be)) return;
    d = g->tert[bd];
    mask = ((d >> 1) | 0xFC) ^ 3;
    a = (d & 1) ? d : (d & 0xF8);
    process_switch_effects(p, a, mask);
}

/* update_variable_wind_tile (&3f18): a wind that turns with the frame counter,
   or in the two flipped caverns a steady downdraught */
static void tile_variable_wind(struct P *p, int flp)
{
    struct G *g = p->g;
    int a, c, ang;
    if (p->waterline & 128) return;
    if (flp & 0x80) { wind_from_a(p, 0x70); return; }
    ang = ((g->frm << 2) & 255) | (g->frm >> 7);
    a = (read_rnd_byte(g, 0x3F2A, 1) & 0x1F) ^ p->tileY;
    c = a >> 7; a = (a << 1) & 0x7F;
    if (p->tileX & 128) a = ((a & 0x3F) + 0x28 + c) & 255;
    vec_from_mag_angle(p, a, ang);
    wind_apply(p);
}

/* update_metal_door_tile and update_stone_door_tile (&3e95): for obstruction
   and collision the tile is whatever the door, open or closed, amounts to;
   otherwise the door object is made */
static int tile_door(struct P *p, int t, int bd, int flp)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int dtype = (t == 3) ? 0x3C : 0x3E, orient, d, open, openF, y;
    if (bd == g->doorSup) return t;              /* an obstruction check has it suppressed */
    orient = ((flp >> 7) ^ (flp >> 6)) & 1;      /* one flip: a vertical door */
    d = g->tert[bd];
    if (!(d & 128)) d >>= 1;                     /* not tertiary: DOOR_FLAG_MOVING stands in for opening */
    open = (d >> 1) & 1;
    openF = open ? 0 : 0xFF;
    if (!(g->mode & 0x80)) t = g->tab[T_DOORTILES + (orient << 1) + open];
    if (g->mode & 0x40) return t;
    y = create_from_tertiary(p, dtype + orient, 0, bd, flp);
    if (y >= 0) {
        OS(O_TY, y, orient << 1);
        OS(O_STATE, y, ((orient ? p->tileY : p->tileX) - 1) & 255);
        OS(O_TX, y, openF);
    }
    return t;
}

static int tile_effect(struct P *p, int t, int flp)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int bd, be, y;
#ifdef HOST_DEBUG
    printf("  tile %02x,%02x type %02x mode %02x%s" "\n", p->tileX, p->tileY, t, g->mode,
           (t < 0x10 && (g->tab[T_RTFLAGS + t] & g->mode)) ? " routine" : "");
    fflush(stdout);
#endif
    if (t >= 0x10 || !(g->tab[T_RTFLAGS + t] & g->mode)) return t;
    if ((g->mode & 0x80) && g->feedMode) {       /* plotting: the game's call, at the same tile */
        int v = read_site(g, SITE_TILE);
        if ((v & 0xFFFF) != ((p->tileY << 8) | p->tileX)) fault(g, 14, v & 0xFFFF);
    }
    bd = TERT_DATA(g, p->tileX, p->tileY); be = TERT_TYPE(g, p->tileX, p->tileY);
    switch (t) {
    case 0x00: tile_invisible_switch(p, bd, be); break;
    case 0x01:                                   /* update_transporter_tile: its beam, at the tile's middle */
        y = create_from_tertiary(p, 0x41, 0, bd, flp);
        if (y >= 0) { OS(O_XF, y, 0x40); OS(O_YF, y, 0x80); }
        break;
    case 0x03: case 0x04: return tile_door(p, t, bd, flp);
    case 0x02:                                   /* update_tile_with_object_from_data: the game marks it a placeholder too */
        y = create_from_tertiary(p, g->tert[bd] & 0x7F, 0, bd, flp);
        if (y >= 0) OS(O_TYPE, y, 0x49);
        break;
    case 0x05: case 0x06: case 0x07:             /* update_tile_with_object_from_type */
        create_from_tertiary(p, g->tab[T_TERTTYPE + be], 0, bd, flp);
        break;
    case 0x08: create_from_tertiary(p, 0x42, 0, bd, flp); break;   /* update_switch_tile */
    case 0x09: case 0x0A: tile_nest_or_pipe(p, bd, be, flp); break;
    case 0x0B:                                   /* update_constant_wind_tile; without data, the lab's river */
        if (bd == 0) { if (!(g->frm & 0x10)) tile_water(p, flp); }
        else wind_from_a(p, g->tert[bd]);
        break;
    case 0x0C: if (bd) create_from_tertiary(p, 0x3B, 0, bd, flp); break;   /* update_engine_tile */
    case 0x0D: tile_water(p, flp); break;
    case 0x0E: tile_variable_wind(p, flp); break;
    case 0x0F:                                   /* update_mushroom_tile: in an event a ball would be made; a touch drugs the player */
        mushroom_effect(p, (flp >> 6) & 1, p->slot == 0);
        break;
    default: fault(g, 3, t); break;
    }
    return t;
}

/* ---- the switch, bush and placeholder objects (&499d, &4ba9, &4b64) ---------------------- */

static void update_switch(struct P *p)
{
    int c = 0, a;
    if (!(p->touch & 128)) c = can_trigger_switches(p, p->touch, p->data);
    p->tx = (c << 7) | (p->tx >> 1);             /* pressed now; the rest is history, to press only once */
    if (p->tx & 128) {
        a = (p->tx << 1) & 255;
        if (a == 0) {
            p->data ^= 1;
            play_sound(p->g, 35);
            process_switch_effects(p, p->data, 0xFF);
        }
    }
    p->xFlip = ((p->data & 1) << 7) | (p->xFlip >> 1);
    gain_energy_and_flash(p, 0x1E);
}

/* set_this_object_velocities_to_zero_and_position_from_previous_position: bushes stay put */
static void update_bush(struct P *p)
{
    p->vel[0] = p->vel[2] = 0;
    set_position_from_previous(p);
}

/* update_placeholder_object (&4b64): what a tile with an object from its data
   holds until something disturbs it or, unless it is equipment, the player
   comes into view; then it becomes the real thing */
static void update_placeholder(struct P *p)
{
    struct G *g = p->g;
    if (!(p->touch & 128) && can_trigger_switches(p, p->touch, p->data)) goto convert;
    if (p->fc16 != 0) goto stay;
    if (range_of_type(g, p->data) == 9) goto stay;
    if (obstruction_between(p, 0, 0x80)) goto stay;
convert:
    p->type = p->data;
    p->energy = 0xFF;
    return;
stay:
    update_bush(p);
}

/* ---- transporter beams (&4d86) and engine fires (&4c15) ------------------------------------ */

/* check_if_object_hit_by_remote_control (&0bc5): 0 when the player has fired a
   remote control device at this object */
static int hit_by_remote_control(struct P *p) { return hit_by_control(p, 0x4E); }

/* consider_toggling_lock (&31ac): the remote control locks and unlocks a door
   or a transporter beam, but only for someone carrying the key of its colour.
   A door that is unlocked by it starts opening; one that is locked stops
   where it is. */
static void toggle_lock(struct P *p, int isDoor)
{
    struct G *g = p->g;
    int a, c, x;
    a = isDoor ? p->data : ((p->data + 0x60) & 255) >> 1;   /* a beam uses keys three to six */
    x = a >> 4;
    if (x >= 19 || !(g->collected[x] & 128)) return;        /* that key has not been found */
    a = p->data ^ 1;                                        /* lock, or unlock */
    if (isDoor) {
        c = a & 1;
        a = (a >> 1) & 0xFE;                                /* it stops moving while locked */
        if (!c) a |= 1;                                     /* and opens when it is unlocked */
        a = ((a << 1) | c) & 255;
    }
    p->data = a;
    play_sound(g, 13);
}

static void update_transporter_beam(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int a = p->data, x = (a >> 1) & 0x0F, c = a & 1, y = p->touch, v;
    if (c) v = 0xB0;                             /* a stationary beam */
    else {
        c = 0;
        if (!(y & 128) && !(OT(O_FLAGS, y) & 0x10)) {   /* something to send, unless it is already on its way */
            OS(O_TX, y, g->tab[T_TRANSX + x]); OS(O_TY, y, g->tab[T_TRANSY + x]);
            OS(O_FLAGS, y, OT(O_FLAGS, y) | 0x10); OS(O_TIMER, y, 0x20);
            OS(O_VX, y, p->vel[0]); OS(O_VY, y, p->vel[2]);
            c = 1;                               /* the sound leaves the carry set */
        }
        if (p->flags & 4) goto colour;           /* just made: it keeps its place this frame */
        v = add8(p, p->state, 0x20, c);
        if (v >= 0xB1) v = (v - 0xB0) & 255;
    }
    p->state = v;
    if (!(p->yFlip & 128)) v = neg8(v);          /* a base in the floor: the beam moves down */
    p->pf[2] = (v - 1) & 255;
colour:
    if (!hit_by_remote_control(p)) toggle_lock(p, 1);   /* &31ac, the door */
    p->pal = g->tab[T_TRANSPAL + ((p->fc >> 2) & 3)];
}

static void update_engine_fire(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int a = p->data, y = p->touch, c, v, pal, xf, r, a4, c1;
    if (a & 3) { p->state = a & 3; goto hide; }  /* switched off */
    p->state = (p->state + 1) & 255;
    if (p->state & 128) p->data = (a + 2) & 255; /* burnt out after 256 frames */
    r = read_rnd_byte(g, 0x4C21, 3);
    if (r < p->state) goto hide;                 /* the older the fire, the more often it hides */
    r = (r << 1) & 255; p->xFlip = r;
    r = (r << 1) & 255; p->yFlip = r;
    if (!(y & 128)) OS(O_VX, y, (OT(O_VX, y) + 1) & 255);   /* it pushes what touches it */
    read_rnd_byte(g, 0x4C38, 2);                 /* the particle's place in the tile */
    p->angleB5 = 0;
    add_particles_t(p, 1, p->ps[0], p->ps[2], 0x81, 0x42, 0x37);
    a = (g->frm + p->ps[2]) & 255; c = (g->frm + p->ps[2]) >> 8;
    if ((a & 3) == 0) {                          /* 1 in 4: it blows things away */
        g->accDmg = 0x80 | (g->accDmg >> 1);
        g->accPower = 0x50;
        accelerate_all(p, 0x14);
        play_sound(g, 41);
        c = 1;                                   /* the sound leaves the carry set */
    }
    pal = 0x34;
    v = g->frm;                                  /* an x fraction between &90 and &cf, from the frame counter */
    a4 = ((v << 1) | c) & 255; c1 = v >> 7;
    a4 = ((a4 << 1) | c1) & 255; c1 = (v >> 6) & 1;
    a4 = ((a4 << 1) | c1) & 255; c1 = (v >> 5) & 1;
    a4 = ((a4 << 1) | c1) & 255; c1 = (v >> 4) & 1;
    xf = add8(p, a4, v, c1) & 0x3F;
    xf = add8(p, xf, 0x90, p->cy);
    goto set;
hide:
    pal = 0; xf = 0x40;                          /* behind the tile */
set:
    p->pal = pal; p->pf[0] = xf;
}

/* ---- doors (&4c83) --------------------------------------------------------------------------- */

static void update_door(struct P *p)
{
    struct G *g = p->g;
    int y = p->touch, xo, d, f9f, colour, pair, slow, spd, fr, v, yv, a, c;
    if (!(y & 128) && !can_trigger_switches(p, y, p->data)) p->touch = 0x80 | (p->touch >> 1);   /* too light to count */
    p->yFlip >>= 1;
    xo = p->ty;                                  /* 0 across, 2 down */
    p->ps[xo] = p->state;                        /* fixed to its tile */
    p->pf[xo] = 0xFF;
    g->doorSup = p->tdataOff;
    if (!hit_by_remote_control(p)) toggle_lock(p, 0);   /* &31ac, the transporter beam */
    g->doorSup = 0x80 | (g->doorSup >> 1);
    d = p->data | 4;                             /* moving, by default */
    f9f = (((d >> 1) & 1) << 7) | ((d & 1) << 6) | (d >> 3);   /* opening, locked */
    slow = (d >> 3) & 1;
    colour = (d >> 4) & 7;
    pair = colour & 3;
    if (p->energy >= g->tab[T_DOORENERGY + pair]) p->energy = 0xFF;
    else if (slow) p->energy = 0;                /* being destroyed: it explodes */
    else { d |= 8; p->energy = d; slow = 0; }    /* marked as being destroyed (and, as the original does, its energy is the data byte) */
    spd = g->tab[T_DOORSPEED + pair];
    if (slow) spd = 1;
    if (!(f9f & 128)) {                          /* closing: at half speed, and barely when something is in the way */
        spd = (spd >> 1) ^ 255;
        if (!(p->touch & 128)) spd = 0xFF;
    }
    fr = p->tx ^ 0x80;
    v = sub8(p, fr, spd, 1);
    if (p->ov) {                                 /* the end of its track */
        yv = prevent_overflow(p, v);
        if (!(yv & 128)) goto stop;              /* closed */
        if (pair != 0) goto skip_stop;
        if (g->doorTimer >= 0x14) goto skip_stop;
        goto toggle;                             /* the self-closing kinds, after their forty frames */
stop:
        d &= 0xFB;
skip_stop:
        if (p->touch & 128) goto set_from_y;
        if (f9f & 0x40) goto set_from_y;         /* locked */
        if (pair != 0) goto toggle;
        if (g->doorTimer != 0) goto set_from_y;
        g->doorTimer = 0x3C;
toggle:
        d ^= 2;                                  /* opening becomes closing, and back */
        play_sound(g, (d & 2) ? 42 : 43);
set_from_y:
        v = yv;
    }
    v ^= 0x80;
    a = sub8(p, v, p->tx, 1);
    c = a >= 0x80;
    p->vel[xo] = (c << 7) | (a >> 1);
    p->tx = v;
    a = add8(p, v, 0x10, 0);
    p->pf[xo] = a;
    p->ps[xo] = add8(p, p->state, 0, p->cy);
    if (p->energy == 0) d |= 4;
    p->data = d;
    g->tert[p->tdataOff] = d;
    a = g->tab[T_DOORPAL + colour];
    if (!(f9f & 0x40)) a &= 0x0F;                /* unlocked: the lock's colour goes black */
    p->pal = a;
}

/* ---- hives (&4baf) and dense nests (&4789) ------------------------------------------------- */

static void update_hive(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int spawnType = (p->data >> 2) & 255, r, x, a;
    p->state = spawnType;
    consider_absorbing(p, spawnType);            /* hives take their own spawn back */
    give_min_energy(p, p->touch);                /* the original loads its minimum of 70 into A but the routine takes Y: so it is the touching byte */
    if (g->frm % 4 != 0) return;
    if (p->data & 3) return;                     /* not active */
    find_or_count(p, spawnType, 0x7F, 1, 0);     /* how many of its spawn are about */
    r = read_site(g, 0x4BCA);                    /* three draws, in the order the game makes them */
    r &= read_rnd_byte(g, 0x4BCD, 0);
    r &= read_rnd_byte(g, 0x4BCF, 2) & 7;
    if (r < p->count) return;                    /* the more there are, the less likely another */
    play_sound(g, 40);
    x = find_or_count(p, 0x0E, 0x86, 0, 0);
    if (!(x & 128)) return;                      /* not with a big fish or flying enemies about */
    p->angleB5 = p->xFlip & 0x80;                /* out to the left or the right, as the hive faces */
    vec_from_mag_angle(p, 0x20, p->angleB5);
    x = create_child(p, spawnType);
    if (x < 0) return;
    OS(O_TARGET, x, p->slot);
    a = (p->xFlip & 128) ? 0x20 : 0xA0;          /* an unflipped hive's spawn are the more aggressive */
    OS(O_STATE, x, a);
    if (a & 128) OS(O_PALETTE, x, OT(O_PALETTE, x) ^ 0x3B);
}

static void update_dense_nest(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y = p->touch;
    if ((y | read_rnd_byte(g, 0x478A, 3)) & 128) return;   /* 1 in 2: what touches it stops dead */
    OS(O_VX, y, p->vel[0]); OS(O_VY, y, p->vel[2]);
}

/* ---- the rest of the menagerie ------------------------------------------------------------ */

/* consider_firing_at_player_and_move_robot (&4864) and _triax (&4861): a little
   energy back, a shot at the player or a chatter, then flight */
static void fire_and_move_hovering(struct P *p, int proj, int ups)
{
    while (ups-- > 0) { p->energy = (p->energy + 1) & 255; if (p->energy == 0) p->energy = 255; }
    find_and_fire(p, p->energy >> 1, proj, 0x81, proj);
    move_hovering_npc(p);
}

static void update_hovering_robot(struct P *p)
{
    struct G *g = p->g;
    if (!gain_energy_and_flash(p, g->tab[T_ROBOTMINE + (p->type - 0x1C)])) return;
    if ((read_rnd_byte(g, 0x4809, 3) >> 1) == 0) play_sound(g, 32);   /* 1 in 128 */
    if (read_rnd_byte(g, 0x4815, 0) >= 0x40) { move_hovering_npc(p); return; }
    fire_and_move_hovering(p, 0x18, 1);
}

static void update_gargoyle(struct P *p)
{
    struct G *g = p->g;
    int d = p->data;
    if ((g->tab[T_GARG + d] & p->fc) == 0)
        create_projectile(p, g->tab[T_GARG + 5 + d], g->tab[T_GARG + 10 + d], g->tab[T_GARG + 15 + d]);
    gain_energy_and_flash(p, 0x5A);
}

/* set_spacesuit_sprite_and_palette (&38d0) for anyone but the player */
static void suit_sprite_and_palette(struct P *p, int a, int yy)
{
    int flsh, pal;
    if (!(p->child & 128)) { p->xFlipP = yy; sprite_from_angle(p, a); }
    flsh = (((p->fc & 0x1F) << 1) & 255) >= p->energy;
    pal = p->palDefault;
    if (flsh) pal = p->pal ^ 0x0B;
    p->pal = pal;
}

static void update_crew_member(struct P *p)
{
    walk_state(p, p->data);                      /* with X = the data byte, as the original leaves it */
    energy_up_if_not_zero(p);
    consider_flipping(p, 7);
    suit_sprite_and_palette(p, 0xC0, p->xFlip);
}

static void update_power_pod(struct P *p)
{
    if (p->energy) p->energy--;
    p->pal = p->g->tab[T_OBJPAL + p->type] & 0x7F;
    if (p->fc16 < 2) { p->pal ^= 0x30; play_sound(p->g, 23); }   /* it pulses */
}

static void update_blue_death_ball(struct P *p)
{
    struct G *g = p->g;
    int y = damaged_by_projectiles(p), a;
    if (!(y & 128) || (g->tbColl & 128)) { explode_with_duration(p, 0x10); return; }
    if (p->energy) p->energy--;
    if (p->energy == 0) { explode_with_duration(p, 0); return; }
    p->vec[0] = p->vel[0]; p->vec[2] = p->vel[2];
    a = angle_from_vec(p);
    p->angleB5 = a ^ 0x80;                       /* the trail leaves the rear */
    add_particles_t(p, 1, p->ps[0], p->ps[2], 0x08, 0x01, 0x2C);
}

static void update_cannonball(struct P *p)
{
    int y = damaged_by_projectiles(p);
    p->acc[2] = (p->acc[2] - 1) & 255;           /* no gravity */
    if (!(y & 128)) damage_slot(p, y, 0xAA);
    update_blue_death_ball(p);
}

static void update_maggot_machine(struct P *p)
{
    struct G *g = p->g;
    int x = g->frm & 0x3F;
    if (x == 0) {
        if (p->ps[2] >= p->wlRow) {              /* under water: the end of the world begins */
            g->quake = 0x80; g->flood = 0x80;
            explode_with_duration(p, 0x80);
            return;
        }
        p->xFlip ^= 0x80;                        /* a squeal and a turn */
    }
    p->pal = g->tab[T_OBJPAL + p->type] & 0x7F;
    if (x < 8) p->pal ^= 0x30;
}

static void update_destinator(struct P *p)
{
    struct G *g = p->g;
    if (g->shipMoving & 128) return;
    if (!(g->tert[0x28] & 1)) {                  /* back in the ship: it leaves */
        g->shipMoving = 0x80 | (g->shipMoving >> 1);
        play_sound(g, 24);
    }
    p->pal = g->tab[T_OBJPAL + p->type] & 0x7F;
    if ((p->fc & 0x1F) < 1) { p->pal ^= 0x30; play_sound(g, 25); }
}

static void update_empty_flask(struct P *p)
{
    if (!(p->g->inWater & 128)) change_type(p, 0x4D);
}

static void update_full_flask(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y = p->touch, start = 0, m;
    if (!(y & 128)) {
        m = inv_neg(p->vel[0]); if (inv_neg(p->vel[2]) > m) m = inv_neg(p->vel[2]);
        if (m >= 0x0A) start = 1;
    }
    if (!start && g->preMag >= 0x14) start = 1;
    if (start) p->timer = 0x10;                  /* knocked: it spills */
    if (p->timer == 0) return;
    if (!(y & 128) && OT(O_TYPE, y) == 0x37) OS(O_FLAGS, y, OT(O_FLAGS, y) | 0x20);   /* and puts out a fireball */
    p->angleB5 = 0xC0;
    add_particles_t(p, 8, p->ps[0], p->ps[2], 0x97, 0x41, 0x58);
    p->timer--;
    if (p->timer == 0) change_type(p, 0x4C);
}

static void update_sucking_nest(struct P *p)
{
    struct G *g = p->g;
    int x = p->data, t, y, r, dmg = 2;
    if (!(p->touch & 128)) play_sound(g, 44);    /* &4e2d, when it has hold of something */
    p->pal = g->tab[T_SUCKPAL + x] >> 1;
    if (p->fc16 != 0) {
        t = g->tab[T_SUCKTRIG + x];
        if (t & 128) p->state = t;               /* anything sets it off */
        else { y = t; if (t == 0x55) y = 0x0B; r = find_or_count(p, t, y, 0, 0); p->state = r ^ 0xFF; }
    }
    if (p->state & 128) {
        g->accSign = ((g->tab[T_SUCKPAL + x] & 1) << 7) | (g->accSign >> 1);
        g->accPower = g->tab[T_SUCKPOW + x];
        accelerate_all(p, 0xFF);
        r = read_rnd_byte(g, 0x4E1F, 2); p->xFlip = r;
        if (r == 0x50) dmg = 0x50;
    }
    if (p->touch & 128) return;
    damage_slot(p, p->touch, dmg);
}

static void update_lightning(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y = p->touch, a = 0, t, x, v;
    if (!(y & 128)) {
        t = OT(O_TYPE, y);
        if (range_of_type(g, t) != 4 && t != 0x40 && t != 0x44 && t != 0x37) {
            if (t != 0x01) damage_slot(p, y, 0x50);
            a = y ^ 0xFF;
        } else a = t;
    }
    x = p->state;
    v = (((a | g->tbColl) ^ 0xFF) | p->state) & 255;
    if (!(v & 128)) {                            /* it hit something: it shrinks from here */
        if (!(x & 128)) x = neg8(x);
        if (x == 0) x = 0xFE;
    }
    p->timer = (p->timer - 1) & 255;
    if (p->timer == 0xE7) a = p->timer;          /* after 25 frames it turns anyway */
    else {
        x = (x + 1) & 255;
        if (x == 0) { p->flags |= 0x20; return; }
        a = x;
    }
    if (inv_neg(a) >= 4) a = (a & 128) ? 0xFC : 4;   /* keep_within_range */
    p->state = a;
    change_sprite(p, (0x6C + inv_neg(a)) & 255);
    a = p->fc;
    p->yFlip = ((a & 1) << 7) | (p->yFlip >> 1); a >>= 1;
    p->xFlip = ((a & 1) << 7) | (p->xFlip >> 1);
    p->acc[2] = (p->acc[2] - 1) & 255;
    p->vel[0] = p->pvel[0]; p->vel[2] = p->pvel[2];
}

static void update_plasma_ball(struct P *p)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y = p->touch, t, a, n;
    if (!(y & 128)) {
        t = OT(O_TYPE, y);
        if (t != 0x40 && t != 0x44 && t != 0x37) { turn_into_fireball(p, 13); return; }
    }
    a = g->inWater | read_rnd_byte(g, 0x4A94, 0);
    a |= read_rnd_byte(g, 0x4A96, 3);
    if (!(a & 128)) { remove_plasma_or_fireball(p); return; }   /* under water it fizzles, 1 in 4 */
    if (p->energy) p->energy--;
    if (p->energy == 0) { p->flags |= 0x20; return; }
    n = (p->energy >= 3) ? 3 : 0x1E;
    add_particles_t(p, n, p->ps[0], p->ps[2], 0x91, 0x02, 0x00);
}

static void update_inactive_grenade(struct P *p)
{
    struct G *g = p->g;
    if (!(p->touch & 128)) p->energy &= 0x7F;    /* consider_disturbing_object */
    if (p->energy & 128) update_bush(p);
    if (g->held == p->slot) { p->state = p->slot; return; }   /* held: remembered */
    if (p->state == 0) return;
    change_type(p, 0x12);                        /* dropped after being held: live */
}

static void update_active_grenade(struct P *p)
{
    int t = p->timer;
    if (p->energy == 0) { explode_with_duration(p, 0x0A); return; }
    if (t >= 0x60) { explode_with_duration(p, 0x10); return; }
    p->timer = (t + 1) & 255;
    if ((t & 0x0F) == 0) play_sound(p->g, 21);
    p->pal = p->g->tab[T_TRANSPAL + ((t >> 2) & 3)];
}

static void update_invisible_debris(struct P *p)
{
    if (p->energy) p->energy--;
    if (p->energy == 0) p->flags |= 0x20;
}

static void update_big_fish(struct P *p)
{
    int a = 0x10;
    consider_absorbing(p, 0x10);
    give_min_energy(p, 0x19);
    if (p->waterline < 0x32) return;             /* out of the water it does nothing */
    consider_finding_target(p, 0x10, 0x10);
    update_path(p);
    if (p->tflags & 128) a = 0x20;
    move_towards(p, a, 2, 0xFF);
    consider_flipping(p, 3);
}

static void update_coronium(struct P *p, int crystal)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int y = p->touch, t, w, a, c, r;
    if (crystal) {
        p->timer = (p->timer + 2) & 255;
        if (p->timer & 128) { explode_with_duration(p, 0x0A); return; }
    }
    if (!(y & 128)) {
        if (y == 0) goto touching_player;
        t = OT(O_TYPE, y);
        if (t == 0x55 || t == 0x58) {            /* coronium on coronium */
            OS(O_FLAGS, y, OT(O_FLAGS, y) | 0x20);
            w = g->tab[T_OBJFLAGS + t] & 7;
            a = add8(p, w, p->weight, 1);
            c = a >> 7; a = (a << 1) & 255;
            a = add8(p, a, 3, c);
            explode_with_duration(p, a);
            return;
        }
    }
    r = read_rnd_byte(g, 0x41EB, 1) & 0xC0;
    if ((r | g->held) != p->slot) goto palette;  /* held: radiation 1 in 4 */
touching_player:
    if (!((g->radImm | p->waterline) & 128)) damage_slot(p, 0, 8);
palette:
    p->pal = (read_site(g, 0x4203) & 255) >> 1;
}

/* update_inactive_or_active_chatter (&48a7) */
static void chatter_common(struct P *p)
{
    struct G *g = p->g;
    int c;
    if (g->whistle1 & 128) { p->timer = 0x80; p->state = 0x80; }
    check_for_npc_stimuli(p, 7);
    update_path(p);
    c = p->stimuli & 1; p->stimuli >>= 1;
    if (c) g->chatterRes = (g->chatterRes + 1) & 255;
}

static void update_inactive_chatter(struct P *p)
{
    struct G *g = p->g;
    chatter_common(p);
    if (!(p->timer & 128)) return;
    p->energy = p->timer;
    g->chatterRes = (g->chatterRes - 1) & 255;
    if (g->chatterRes & 128) { g->chatterRes = (g->chatterRes + 1) & 255; return; }
    change_type(p, 0x01);
}

static void update_active_chatter(struct P *p)
{
    struct G *g = p->g;
    int x, a;
    chatter_common(p);
    flash_if_damaged(p, 0);
    if (p->energy == 0) { change_type(p, 0x38); return; }
    consider_flipping(p, 0x1F);
    if (g->frm % 8 == 0) {                       /* every eight frames, lightning at a turret or flying enemy in front */
        x = find_or_count(p, 0x20, 0x86, 0, 0);
        if (!(x & 128)) {
            a = add8(p, p->angleB5, 0x40, p->findsCarry);
            p->xFlip = a;
            if (!((a ^ p->flags) & 128)) {
                a = sub8(p, p->angleB5 & 0x7F, 0x0A, p->cy);
                if (a >= 0x6C) { p->timer = a; play_sound(g, 34); create_projectile(p, 0x28, 0, 0x32); }
            }
        }
    }
    if (p->timer) {                              /* chattering */
        p->timer--;
        if (read_rnd_byte(g, 0x4914, 0) >= 0xC0) { read_rnd_byte(g, 0x491A, 3); p->pal = 0x4B; }
    }
    /* whistle two would have it produce a power pod: the player has no whistles here yet */
    if ((p->touch | p->target) == 0) p->tflags = 0;
    thrust_towards_target(p);
}

/* consider_teleporting_to_random_tile_near_player (&488b), from inside the rock */
static void teleport_near_player(struct P *p, int limit)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int r, a;
    if (!(g->surr & 128)) return;
    p->tflags = 0x40; p->target = 0;
    r = read_site(g, 0x2748);
    a = add8(p, r & 3, OT(O_X, 0), (r >> 8) & 1);
    a = sub8(p, a, 1, p->cy); p->tx = a; p->tileX = a;
    a = add8(p, read_rnd_byte(g, 0x2754, 0) & 3, OT(O_Y, 0), p->cy);
    a = sub8(p, a, 1, p->cy); p->ty = a; p->tileY = a;
    if (limit > a) a = limit;
    p->ty = a;
    p->flags |= 0x10; p->timer = 0x20;
}

static void teleport_away(struct P *p)
{
    p->ty = 0;
    p->flags |= 0x10; p->timer = 0x20;
}

static void update_triax(struct P *p)
{
    struct G *g = p->g;
    int a, c, x;
    if (consider_absorbing(p, 0x4A) == 0) { g->tert[0x9D] = 0x80; teleport_away(p); return; }   /* the destinator goes back to the lab */
    if (!(p->tflags & 128) && p->fc == 0) { teleport_away(p); return; }
    if (p->energy < 0x40 && read_rnd_byte(g, 0x4720, 0) < 4) { teleport_away(p); return; }
    x = (read_rnd_byte(g, 0x4726, 2) >= 8) ? 0x13 : 0x12;
    fire_and_move_hovering(p, x, 2);
    c = p->energy >= 5;
    a = ((p->energy << 1) | c) & 255;
    a |= read_rnd_byte(g, 0x4738, 3);
    a |= read_rnd_byte(g, 0x473A, 1);
    if (!(a & 1)) { teleport_away(p); return; }
    a = (g->eastOf76 ^ 0x80) | g->flood;
    if (!(a & 128) && (read_rnd_byte(g, 0x4749, 3) & 3) == 0) { teleport_away(p); return; }
    if ((read_site(g, 0x474F) & 255) == 0) { teleport_away(p); return; }
    update_crew_member(p);
    teleport_near_player(p, 0);
}

static void update_clawed_robot(struct P *p)
{
    struct G *g = p->g;
    int c, x = p->type - 0x22, a;
    c = (p->flags & 8) == 8;
    p->state = ((c << 7) | (p->state >> 1)) >> 1;
    a = give_min_energy(p, g->tab[T_CLAWEN + x]);
    if (a == 0) return;
    a = (a & 0xF8) >> 1;
    g->clawTel[x] = a;
    a = (a << 1) & 255;
    if (!(a >= 0x8C && ((p->tflags & 0xC0) | p->fc) != 0)) {
        if (p->state == 0) { g->clawAvail[x] = 0; teleport_away(p); return; }
    }
    teleport_near_player(p, 0x46);
    if ((read_site(g, 0x4852) >> 1) == 0) play_sound(g, 33);   /* 1 in 128 */
    fire_and_move_hovering(p, 0x13, 2);
}

static void update_alien_weapon(struct P *p)
{
    energy_up_if_not_zero(p);                    /* it only recharges; the player is what fires it */
}

static void call_update_routine(struct P *p)
{
    int t = p->type;
    if (t == 0x00) update_player(p);
    else if (t == 0x43 || t == 0x45 || t == 0x64) ;               /* update_inert_object: RTS */
    else if (t == 0x3A) update_giant_block(p);
    else if ((t >= 0x51 && t <= 0x63 && t != 0x55 && t != 0x58)) update_collectable(p);
    else if (t == 0x2E || t == 0x2F) update_bird(p, 0);
    else if (t == 0x30) update_bird(p, 1);
    else if (t == 0x31) update_bird(p, 2);
    else if (t >= 0x29 && t <= 0x2D) update_imp(p);
    else if (t == 0x03) update_fluffy(p);
    else if (t >= 0x06 && t <= 0x08) update_frogman(p, t - 0x06);
    else if (t == 0x09) update_red_slime(p);
    else if (t == 0x0A) update_green_slime(p);
    else if (t == 0x0B) update_yellow_slime(p);
    else if (t == 0x0F) update_worm(p);
    else if (t == 0x27) update_maggot(p);
    else if (t == 0x10 || t == 0x11) update_piranha_or_wasp(p);
    else if (t >= 0x1C && t <= 0x1E) update_rolling_robot(p);
    else if (t == 0x1F || t == 0x20) update_turret(p);
    else if (t == 0x18) update_pistol_bullet(p);
    else if (t == 0x36) update_red_drop(p);
    else if (t == 0x37) update_fireball(p);
    else if (t == 0x39) update_moving_fireball(p);
    else if (t == 0x1A || t == 0x1B) update_hovering_ball(p, t == 0x1B);
    else if (t == 0x42) update_switch(p);
    else if (t == 0x41) update_transporter_beam(p);
    else if (t >= 0x3C && t <= 0x3F) update_door(p);
    else if (t == 0x04 || t == 0x05) update_hive(p);
    else if (t == 0x0C) update_dense_nest(p);
    else if (t == 0x21) update_hovering_robot(p);
    else if (t == 0x28) update_gargoyle(p);
    else if (t == 0x02) update_crew_member(p);
    else if (t == 0x4B) update_power_pod(p);
    else if (t == 0x15) update_cannonball(p);
    else if (t == 0x16) update_blue_death_ball(p);
    else if (t == 0x48) update_maggot_machine(p);
    else if (t == 0x4A) update_destinator(p);
    else if (t == 0x4C) update_empty_flask(p);
    else if (t == 0x4D) update_full_flask(p);
    else if (t == 0x0D) update_sucking_nest(p);
    else if (t == 0x32) update_lightning(p);
    else if (t == 0x19) update_plasma_ball(p);
    else if (t == 0x50) update_inactive_grenade(p);
    else if (t == 0x12) update_active_grenade(p);
    else if (t == 0x35) update_invisible_debris(p);
    else if (t == 0x0E) update_big_fish(p);
    else if (t == 0x55 || t == 0x58) update_coronium(p, t == 0x58);
    else if (t == 0x38) update_inactive_chatter(p);
    else if (t == 0x01) update_active_chatter(p);
    else if (t == 0x26) update_triax(p);
    else if (t >= 0x22 && t <= 0x25) update_clawed_robot(p);
    else if (t == 0x47) update_alien_weapon(p);
    else if (t == 0x46) update_cannon(p);
    else if (t == 0x4E || t == 0x4F) update_remote_control_device(p);
    else if (t == 0x3B) update_engine_fire(p);
    else if (t == 0x40) update_bush(p);
    else if (t == 0x49) update_placeholder(p);
    else if (t == 0x33 || t == 0x34) update_mushroom_ball(p);
    else if (t == 0x13) update_bullet_trail(p, 2, 0x14);                   /* icer bullet */
    else if (t == 0x14) {                                                  /* tracer bullet */
        p->energy = (p->energy + 1) & 255; if (p->energy == 0) p->energy = 255;
        update_bullet_trail(p, 8, 0x0F); moving_towards_player(p);
    }
    else if (t == 0x17) { update_bullet_trail(p, 6, 0x1E); moving_towards_player(p); }   /* red bullet */
    else if (t == 0x44) update_explosion(p);
    else fault(p->g, 10, t);
}

/* ---- apply_acceleration_to_velocities (&1f01) ------------------------------------------- */

static void apply_acceleration(struct P *p)
{
    struct G *g = p->g;
    int xi, c, a, n, yy, old;
    for (xi = 2; xi >= 0; xi -= 2) {
        c = xi == 2;
        a = p->acc[xi]; n = a & 128;
        a = add8(p, a, p->vel[xi], c);
        if (p->ov) a = (0x7F + p->cy) & 255;
        yy = a;
        if (n) a = neg8(a);
        a = sub8(p, a, 0x3F, 0);
        if (a < 0x40) {
            old = p->vel[xi]; yy = old;
            if (inv_neg(old) < 0x40) yy = (old & 128) ? 0xC0 : 0x40;
        }
        if (g->frm % 16 == 0 && yy != 0) yy = (yy & 128) ? (yy + 1) & 255 : (yy - 1) & 255;
        p->vel[xi] = yy;
    }
}

/* ---- removal ----------------------------------------------------------------------------- */

static void remove_for_touching_and_targeting(struct G *g, int a)
{
    long long *obj = g->obj;
    int x;
    for (x = NSLOT - 1; x >= 0; x--) {
        if (OT(O_TOUCHING, x) == a) OS(O_TOUCHING, x, 128 | (OT(O_TOUCHING, x) >> 1));
        if (((OT(O_TARGET, x) ^ a) & 0x1F) == 0) OS(O_TARGET, x, x);
    }
}

static void demote_to_secondary(struct P *p)
{
    struct G *g = p->g;
    long long *game = g->game;
    int x, q;
    for (x = 31; x >= 0; x--) if ((int)game[G_SECY0 + x] == 0) break;
    if (x < 0) return;                                  /* the background would flash; the object is lost */
    game[G_SECT0 + x] = p->type;
    game[G_SECX0 + x] = p->ps[0];
    game[G_SECY0 + x] = p->ps[2];
    q = (p->pf[0] >> 6) & 3;
    q = (q << 2) | ((p->pf[2] >> 6) & 3);
    game[G_SECE0 + x] = (p->energy & 0xF0) | q;
}

/* check_if_this_object_is_far_away (&111d): carry set if far away */
static int far_away(struct P *p, int y)
{
    struct G *g = p->g;
    int d = (y + 2) & 255, xi, a, rel;
    /* scr: [0] screen_origin_x (&c8), [1] screen_origin_y (&ca), [2..9] &0b91-&0b98:
       start x fraction, -, start y fraction, -, start x, -, start y, - */
    for (xi = 2; xi >= 0; xi -= 2) {
        int sx = g->scr[6 + xi], sxf = g->scr[2 + xi];
        a = sub8(p, sx, p->ps[xi], 1); rel = a;
        a = sub8(p, a, d, 0);
        if (!(a & 128)) return 1;
        a = add8(p, g->tab[T_SCRSZF + xi], sxf, 0);
        a = add8(p, g->tab[T_SCRSZ + xi], rel, p->cy);
        a = add8(p, a, d, 0);
        if (a & 128) return 1;
        d = (d - 2) & 255;
    }
    return 0;
}

/* ---- update_object (&1a17) ---------------------------------------------------------------- */

static void update_object(struct G *g, int slot)
{
    long long *obj = g->obj;
    struct P pp, *p = &pp;
    int a, c, flp, xi, teleporting = 0;
    p->g = g;
    p->slot = slot;
    p->ps[2] = OT(O_Y, slot); p->flags = OT(O_FLAGS, slot); p->prevFlags = p->flags;
    p->xFlip = p->flags; p->yFlip = (p->flags << 1) & 255;
    p->ps[0] = OT(O_X, slot); p->pf[0] = OT(O_XF, slot);
    p->vel[2] = OT(O_VY, slot); p->vel[0] = OT(O_VX, slot);
    p->pvel[2] = p->vel[2]; p->pvel[0] = p->vel[0]; p->pvel[1] = 0;
    p->pf[2] = OT(O_YF, slot);
    p->spr = OT(O_SPRITE, slot); p->prevSpr = p->spr;
    p->pal = OT(O_PALETTE, slot);
    p->type = OT(O_TYPE, slot);
    p->tdataOff = OT(O_TDATA, slot);
    p->tflags = OT(O_TARGET, slot); p->target = p->tflags & 0x1F;
    p->tx = OT(O_TX, slot); p->energy = OT(O_ENERGY, slot); p->ty = OT(O_TY, slot);
    p->touch = OT(O_TOUCHING, slot); p->state = OT(O_STATE, slot); p->timer = OT(O_TIMER, slot);
    p->qps[0] = p->ps[0]; p->qps[2] = p->ps[2]; p->qpf[0] = p->pf[0]; p->qpf[2] = p->pf[2];
    p->ps[1] = p->pf[1] = p->vel[1] = p->acc[1] = p->siz[1] = p->mxp[1] = p->mxf[1] = p->vec[1] = 0;
    p->fc = (((slot << 4) | slot) + g->frm) & 255;
    p->fc16 = p->fc & 15;
#ifdef HOST_DEBUG
    printf("  slot %d start: signs %02x frm %02x\n", slot, g->signs, g->frm);
    fflush(stdout);
#endif
    get_waterline(p, p->ps[0]);
    p->typeFlags = g->tab[T_OBJFLAGS + p->type];
    p->palDefault = g->tab[T_OBJPAL + p->type] & 0x7F;
    p->weight = p->typeFlags & 7;
    p->isStatic = p->weight >= 7;
    if (p->isStatic) p->vel[0] = p->vel[2] = 0;
    p->rawW = g->tab[T_SPRW + p->spr];
    p->siz[0] = p->rawW & 0xF0; p->siz[2] = g->tab[T_SPRH + p->spr] & 0xF8;
    p->acc[0] = p->acc[2] = 0; p->aimAccT = 0; p->objCY = p->objCX = 0; g->preMag = 0; p->child = 0; p->tileAng = 0;
    p->upright = 255; p->visibility = 255;
    add_to_pos(p, 2, p->vel[2], p->vel[2] & 128);
    add_to_pos(p, 0, p->vel[0], p->vel[0] & 128);
    if (slot == 0 && !(g->held & 128))
        p->weight = g->tab[T_PLAYERWEIGHTS + (g->tab[T_OBJFLAGS + OT(O_TYPE, g->held)] & 7)];
    if (slot == g->held) {
        /* a held object rides with the player: centred on its height, beside it */
        int ps = OT(O_SPRITE, 0), h = g->tab[T_SPRH + ps], w = g->tab[T_SPRW + ps], sgn, n, x;
        a = sub8(p, h, p->siz[2], 1); sgn = p->cy;
        c = a & 1; a = (sgn << 7) | (a >> 1);
        a ^= 128; a &= 0xF8;
        a = add8(p, a, OT(O_YF, 0), c);
        p->pf[2] = a; p->heldF[2] = a;
        a = add8(p, OT(O_Y, 0), 0, p->cy);
        a = sub8(p, a, 0, sgn);
        p->ps[2] = a; p->heldX[2] = a;
        a = add8(p, w, 0x0F, p->cy);
        x = 0;
        if (OT(O_FLAGS, 0) & 128) {
            a = add8(p, p->siz[0], 0x10, p->cy);
            x = 0xFF;
            a = inv_neg(a);
        }
        a = add8(p, a, OT(O_XF, 0), 0);
        p->pf[0] = a; p->heldF[0] = a;
        a = add8(p, x, OT(O_X, 0), p->cy);
        p->ps[0] = a; p->heldX[0] = a;
        p->vel[0] = OT(O_VX, 0); p->vel[2] = OT(O_VY, 0);
        p->xFlip = OT(O_FLAGS, 0);
        (void)n;
    }
    maxima(p);
    if (!p->isStatic) {
        check_other_objects(p);
        g->mode = 0x20;
        coll_water_tiles(p);
        c = p->rc;
        if (slot == 0) {
            a = sub8(p, p->tileAng, g->angle, c); a = sub8(p, a, 0x40, p->cy);
            a = inv_neg(a); a >>= 1; c = a & 1; a >>= 1;
            a = add8(p, a, 0xC0, c); a = add8(p, a, g->preMag, p->cy);
            if (p->cy) p->energy = damage_without_destroying(p, a >> 1);
        }
        g->anyB = g->cYF | p->objCY;
        g->collTop = ((p->objCY << 1) & 255) | g->cYS;
        g->wedged >>= 1;
        p->flags &= 0xFD;
        if (!(g->collTop & 128)) {
            if (g->anyB & 128) p->flags |= 2;
        } else if (p->prevFlags & 2) {
            g->wedged = 128 | (g->wedged >> 1);
            if (g->obs[2] != g->obs[0]) {
                a = 0x10;
                if ((g->obs[2] - g->obs[0]) & 128) a = 0xF0;
                add_to_pos(p, 0, a, a & 128);
                maxima(p);
            }
        }
    } else {
        g->anyB = g->collTop = 0; g->cYF = g->cYS = 0;
        g->obs[0] = g->obs[1] = g->obs[2] = g->obs[3] = 0;
    }
    /* which objects are worth keeping, and how far away is too far */
    {
        int tf = p->typeFlags, keep = ((tf >> 4) & 3), far = 0;
        p->removal = (tf << 1) & 255;
        if (keep) {
            int y;
            xi = keep;
            if (xi == 2) {
                int mx = inv_neg(p->vel[0]), my = inv_neg(p->vel[2]);
                if (my > mx) mx = my;
                if (mx < 5 && (g->anyB & 128)) xi++;
            }
            y = g->tab[T_DISTANCES + xi];
            if ((p->fc16 & 3) == 3 && !(p->flags & 0x14) && !((tf & 8) && (g->demat & 128)))
                far = far_away(p, y);
        }
        p->removal = (far << 7) | (p->removal >> 1);
    }
    if (p->flags & 0x10) {
        teleporting = 1;
        if (p->timer == 0) {
            p->flags &= 0xEF;
            p->energy = (p->energy + 1) & 255;
            if (p->energy == 0) p->energy = 255;
            teleporting = 0;
        } else {
            if (p->timer == 0x11) {
                p->ps[2] = 0x11;
                if (slot == 0) g->demat = 0xFF;
            }
            if (p->timer == 0x10) {
                if (slot == 0) g->demat = 0;
                p->pf[2] = ((p->siz[2] ^ 255) & 255) >> 1; p->ps[2] = p->ty;
                p->pf[0] = ((p->siz[0] ^ 255) & 255) >> 1; p->ps[0] = p->tx;
                p->vel[0] = p->vel[2] = 0;
            }
            p->timer = (p->timer - 1) & 255;
        }
    }
    if (!teleporting) {
        if (p->ps[2] < 0x4F) surface_wind(p);
        p->data = g->tert[p->tdataOff];
        call_update_routine(p);
        if (slot == g->held) {
            /* dropped if it has got too far from where it was put; velocities follow the player */
            int drop = 0, yy;
            c = 1;
            for (xi = 2; ; xi -= 2) {
                a = sub8(p, p->heldF[xi], p->pf[xi], c); c = p->cy;
                yy = add8(p, a, 0x30, c);
                a = add8(p, p->heldX[xi], 0, p->cy);
                a = sub8(p, a, p->ps[xi], c);
                if (a != 0 || yy >= 0x60) { drop = 1; handle_dropping(p); set_position_from_previous(p); c = p->cy; }
                else c = 0;
                if (xi == 0) break;
            }
            (void)drop;
            a = p->touch;
            if (a != 0) a = ((g->tab[T_OBJFLAGS + OT(O_TYPE, a)] | a) ^ 128) & 255;
            a |= g->tbColl;
            g->heldColl = a;
            if (a & 128) { OS(O_VX, 0, p->vel[0]); OS(O_VY, 0, p->vel[2]); }
        }
        if (p->energy == 0) {
            /* the type's explosion: 0 indestructible (the player teleports away),
               1 and 3 an explosion with a squeal, 2 a fireball */
            int et = (g->tab[T_RTFLAGS + 0x14 + p->type] >> 6) & 3;
            if (et == 0) { if (slot == 0) consider_teleporting_damaged_player(p); }
            else if (et == 2) turn_into_fireball(p, 7);
            else if (et == 3) { play_sound(g, 16); explode_with_squeal(p); }
            else explode_with_squeal(p);
        }
        a = read_site(g, SITE_VISIBILITY) & 255;
        a >>= 2; a |= 1;
        c = a >= g->redMush;
        a = (c << 7) | (a >> 1);
        a ^= 255;
        p->visibility |= a;
        {
            int tf2 = g->tab[T_OBJFLAGS + p->type] & 0x18;
            if (tf2) {
                int d = p->data;
                if (!(p->flags & 0x20) && (p->removal & 128)) {
                    if (tf2 == 0x10) d |= 128;
                    else d = (d + 4) & 255;
                }
                g->tert[p->tdataOff] = d;
            }
        }
        apply_acceleration(p);
    }
    if (slot != 0) {
        if ((p->flags & 0x20) || (p->removal & 128)) {
            if (!(p->flags & 0x20) && !(p->removal & 0x40)) demote_to_secondary(p);
            remove_for_touching_and_targeting(g, slot);
            if (slot == g->viewpoint) g->viewpoint = 0;
            p->ps[0] = 0; p->ps[2] = 0;
            if (slot == g->held) g->held = 128 | (g->held >> 1);
        }
    }
    flp = (p->xFlip & 128) | ((p->yFlip & 128) >> 1);
    p->flags = ((p->flags & 0xC0) ^ p->flags ^ flp) & 0xF3;
    if (p->ps[2] != 0 && (p->visibility & 128)) g->lastPlotW = g->tab[T_SPRW + p->spr] & 0xF0;
    OS(O_Y, slot, p->ps[2]); OS(O_X, slot, p->ps[0]); OS(O_XF, slot, p->pf[0]);
    OS(O_VY, slot, p->vel[2]); OS(O_VX, slot, p->vel[0]); OS(O_FLAGS, slot, p->flags & 0xFE);
    OS(O_YF, slot, p->pf[2]); OS(O_SPRITE, slot, p->spr); OS(O_PALETTE, slot, p->pal);
    OS(O_TYPE, slot, p->type); OS(O_TDATA, slot, p->tdataOff);
    OS(O_TARGET, slot, (p->tflags & 0xE0) | p->target);
    OS(O_TX, slot, p->tx); OS(O_ENERGY, slot, p->energy); OS(O_TY, slot, p->ty);
    OS(O_TOUCHING, slot, p->touch | 128); OS(O_STATE, slot, p->state); OS(O_TIMER, slot, p->timer);
    if (slot == g->viewpoint) {
        /* the screen follows the viewpoint object, and every tile the scroll
           uncovers whose routine wants to know is told: nests grow their bush,
           turrets and switches appear */
        int i;
        consider_how_to_scroll(p);            /* which redraws if it must, and then */
        update_screen_variables(p);           /* the game does these two regardless */
        prepare_screen(p);
        g->mode = 0x20;
        update_particles(p);                      /* &1e08, before promotion as the game has it */
        if (g->promoteOn) consider_promoting(p);
        if (g->feedMode)
            for (i = 0; i < 10; i++)
                if (g->scr[i] != g->fedScr[i]) { fault(g, 15, (i << 16) | (g->scr[i] << 8) | g->fedScr[i]); break; }
    }
}

/* ---- the CSUB entry: one tick ---------------------------------------------------------------- */

/* every_sixty_four_frames (&c1) to every_two_frames (&c6): the main loop walks
   the frame counter's low bits, counting up from &ff, so the byte is negative
   only while none of the bits it has passed is set */
static int frame_flag(struct G *g, int which)
{
    int a = g->frm, y = 0xFF, x;
    for (x = 5; x >= 0; x--) {
        if (a & 1) y = (y + 1) & 255;
        a >>= 1;
        if (x == which - 1) return y;
    }
    return y;
}

/* get_random_tile_near_player (&2743): a tile within the diameter, in tileX/tileY */
static void random_tile_near_player(struct P *p, int d)
{
    struct G *g = p->g;
    long long *obj = g->obj;
    int half = d >> 1, r, a;
    r = read_site(g, 0x2748);
    a = add8(p, r & d, OT(O_X, 0), (r >> 8) & 1);
    a = sub8(p, a, half, p->cy); p->tileX = a;
    a = add8(p, read_rnd_byte(g, 0x2754, 0) & d, OT(O_Y, 0), p->cy);
    a = sub8(p, a, half, p->cy); p->tileY = a;
}

/* update_events (&259a), once a tick after every object has been updated */
static void update_events(struct G *g, struct P *p)
{
    long long *obj = g->obj;
    int a, c, d, i, x, y, v, t, spawnType;
    p->slot = 0;                                 /* the events act as the player for sounds and particles */
    p->g = g;
    p->vec[1] = p->acc[1] = 0;
    a = 0x67;                                    /* flooding: the lab fills to here */
    if (!(g->flood & 128)) {                     /* otherwise Triax's lab runs */
        g->tert[2] = 0x60;                       /* its machine never runs out of maggots */
        if (frame_flag(g, 1) & 128) {            /* every 64 frames, one more maggot */
            p->tileX = 0x61; p->tileY = 0xD9;
            y = create_new_object(p, 0x27, 4);
            if (y >= 0) {
                OS(O_Y, y, 0xD9); OS(O_X, y, 0x61); OS(O_XF, y, 0x61); OS(O_YF, y, 0x70);
            }
        }
        a = g->tert[0xC2];                       /* the door at the bottom of the lab */
        if (frame_flag(g, 2) & 128) {
            a &= 0xFD;
            if (g->wl[5] < 0xE0) a |= 2;         /* open only when the water is well above it */
        }
        g->tert[0xC2] = a;
        a = ((a & 2) << 3) & 255;
        a = add8(p, a, 0xD2, 0);                 /* &d2 shut, &e2 open: the water drains */
    }
    g->wlDes[1] = a;
    if (g->quake & 128) {                        /* the earthquake worsens, and shakes the screen */
        a = (g->quake << 1) & 255;
        c = a >= read_rnd_byte(g, 0x25E8, 2);
        a = ((a & 0x10) << 1) | c;
        if (a != 0 && (frame_flag(g, 4) & 128) && a != 0x21) {
            g->quake = (g->quake + 1) & 255;
            play_sound(g, 6);
        }
        if ((a >> 1) == 0) read_site(g, 0x25FD);
    }
    /* the four waterlines breathe towards where they should be, two fractions a tick */
    d = (g->frm & 0x20) ? 0xFE : 2;
    for (x = 3; x >= 0; x--) {
        sub8(p, 0x18, g->wl[x], 1);
        a = sub8(p, g->wlDes[x], g->wl[4 + x], p->cy);
        a = add8(p, a, d, p->cy);
        c = a & 128;                             /* the underflow, kept over the clamp */
        a = keep_range(a, 2);
        a = add8(p, a, g->wl[x], 0);
        g->wl[x] = a;
        if (p->cy) g->wl[4 + x] = (g->wl[4 + x] + 1) & 255;
        if (c) g->wl[4 + x] = (g->wl[4 + x] - 1) & 255;
    }
    /* a random tile near the player gets its event routine, and may give up a creature */
    g->mode = 0x10;
    random_tile_near_player(p, 7);
    v = g->world[(p->tileY << 8) + p->tileX];
    t = tile_effect(p, v & 0x3F, v & 0xC0);
    if (t == 0x2D && (frame_flag(g, 3) & 128)) { /* out of solid earth, every sixteen frames */
        a = ((g->flood & 0x80) ^ 0x80) | read_rnd_byte(g, 0x2677, 1);
        if (a < p->tileY) {                      /* the deeper the square, the likelier */
            int go = (g->expTimer & 128) != 0;   /* an explosion always brings them out */
            if (!go) go = (read_rnd_byte(g, 0x2682, 2) & 0x70) == 0;
            if (go) {
                int off = 1;                     /* the world's worms; &02 is its maggots */
                a = read_site(g, 0x268A);
                c = (a & 255) >= 8;
                a = ((c << 7) | ((a & 255) >> 1)) & 255;
                if (!(g->flood & 128) && (g->eastOf76 & 128)) a = neg8(a);
                if (a & 128) off = 2;            /* maggots while flooding or west of &76 */
                y = spawn_from_nest(p, off, off, 6, v & 0xC0);
                if (y >= 0 && (((g->tert[off] << 1) & 255) >= read_rnd_byte(g, 0x26A7, 2))) {
                    OS(O_YF, y, p->vecA);
                    a = sub8(p, OT(O_X, 0), p->tileX, 1); OS(O_VX, y, a);
                    a = sub8(p, OT(O_Y, 0), p->tileY, p->cy); OS(O_VY, y, a);
                    OS(O_STATE, y, 0x80);        /* it wants to dig its way out */
                }
            }
        }
    }
    if (p->tileY < 0x4E && !((g->demat | FROM_MAP(g, p->tileX, p->tileY)) & 128))
        add_particles_t(p, 1, p->tileX, p->tileY, 0x88, 0x47, 0x4D);      /* a star in the sky */
    /* Triax and the clawed robots let themselves back in */
    a = (g->quake - 1) & 255;
    c = a >= 0xC8;
    a = ((c << 7) | (a >> 1)) & g->flood;
    a |= frame_flag(g, 2);
    if (a & 128) {
        if ((read_site(g, 0x26F4) & 255) == 0) {
            a = sub8(p, OT(O_Y, 0), 0x14, 1);
            if ((a | g->flood) & 128) {
                find_or_count(p, 0x26, 0x7F, 1, 0);
                if (p->count == 0) {
                    y = create_new_object(p, 0x26, 4);
                    if (y >= 0) { OS(O_Y, y, 0xFE); OS(O_TARGET, y, 0xC0); }
                }
            }
        }
    }
    if (!(frame_flag(g, 4) & 128)) return;
    x = read_site(g, 0x2718) & 3;
    if (g->clawAvail[x] != 0) return;            /* dormant, or already about */
    g->clawTel[x] = (g->clawTel[x] + 1) & 255;
    if (!(g->clawTel[x] & 128)) return;          /* not enough energy to come back yet */
    y = create_new_object(p, (0x22 + x) & 255, 4);
    if (y < 0) return;
    g->clawAvail[x] = 1;
    OS(O_Y, y, 0xFE); OS(O_TARGET, y, 0xC0);
}

EXPORT long long exile_tick(long long *obj, long long *game, long long *world, long long *tbl, long long *feed, long long *part)
{
    struct G gg, *g = &gg;
    int i;
    g->obj = obj; g->game = game; g->feed = feed; g->part = part;
    g->world = (const u8 *)world; g->tab = (const u8 *)tbl;
    g->fault = 0; g->faultArg = 0;
#define IN(field, idx) g->field = (int)game[idx]
    IN(frm, G_FRAME); IN(angle, G_ANGLE); IN(facing, G_FACING); IN(immob, G_IMMOB); IN(tImmob, G_TIMMOB);
    IN(rotVel, G_ROTVEL); IN(lying, G_LYING); IN(aim, G_AIM); IN(aimVel, G_AIMVEL); IN(aimFlip, G_AIMFLIP);
    IN(jetOk, G_JETOK); IN(inWater, G_INWATER); IN(tbColl, G_TBCOLL); IN(surr, G_SURR); IN(wedged, G_WEDGED);
    IN(signs, G_SIGNS); IN(windSign, G_WINDSIGN); IN(relTX, G_RELTX); IN(relTY, G_RELTY); IN(walkSpd, G_WALKSPD);
    IN(maxAcc0, G_MAXACC0); IN(fireCool, G_FIRECOOL); IN(waterTile, G_WATERTILE);
    IN(weapon, G_WEAPON); IN(fired, G_FIRED); IN(blaster, G_BLASTER); IN(pockUsed, G_POCKUSED);
    IN(eventsOn, G_EVENTSON); IN(promoteOn, G_PROMOTEON);
    g->nPart = (int)(signed char)game[G_NPART];
    IN(orgF[0], G_ORGXF); IN(orgF[2], G_ORGYF); IN(frac[0], G_FRACX); IN(sgn[0], G_SGNX);
    IN(frac[2], G_FRACY); IN(sgn[2], G_SGNY); IN(secs[0], G_SECSX); IN(secs[2], G_SECSY);
    IN(sVel[0], G_SVELX); IN(sVel[2], G_SVELY); IN(newTiles, G_NEWTILES);
    IN(secMode, G_SECMODE); IN(secNext, G_SECNEXT); IN(secShuf, G_SECSHUF); IN(secDist, G_SECDIST);
    g->org[0] = (int)game[G_SCR0]; g->org[2] = (int)game[G_SCR1];
    g->orgF[1] = g->org[1] = g->frac[1] = g->sgn[1] = g->secs[1] = g->sVel[1] = 0;
    for (i = 0; i < 4; i++) g->wlDes[i] = (int)game[G_WLDES0 + i];
    IN(telRem, G_TELREM); IN(telNext, G_TELNEXT); IN(scrollX, G_SCROLLX); IN(scrollY, G_SCROLLY);
    for (i = 0; i < 6; i++) { g->wLo[i] = (int)game[G_WLO0 + i]; g->wHi[i] = (int)game[G_WHI0 + i]; }
    for (i = 0; i < 5; i++) { g->pocket[i] = (int)game[G_POCKET0 + i]; g->telX[i] = (int)game[G_TELX0 + i]; g->telY[i] = (int)game[G_TELY0 + i]; }
    IN(boosterCol, G_BOOSTERCOL); IN(suitCol, G_SUITCOL); IN(cross[0], G_CROSSX); IN(cross[2], G_CROSSY);
    IN(feedMode, G_FEEDMODE); IN(feedPos, G_FEEDPOS); IN(feedEnd, G_FEEDEND); IN(held, G_HELD); IN(demat, G_DEMAT); IN(heldColl, G_HELDCOLL);
    IN(redMush, G_REDMUSH); IN(preAng, G_PREANG); IN(preMag, G_PREMAG); IN(retrieve, G_RETRIEVE); IN(viewpoint, G_VIEWPOINT);
    IN(npcW0, G_NPCW0);
    IN(tgt[0], G_TGTX); IN(tgt[1], G_TGTXF); IN(tgt[2], G_TGTY); IN(tgt[3], G_TGTYF); IN(x17, G_X17); IN(y17, G_Y17);
    IN(wlBlock, G_WLBLOCK); IN(doorSup, G_DOORSUP); IN(routeBest, G_ROUTEBEST);
    IN(expTimer, G_EXPTIMER); IN(flood, G_FLOOD); IN(blueMush, G_BLUEMUSH); IN(immunity, G_IMMUNITY);
    IN(accPower, G_ACCPOWER); IN(accSign, G_ACCSIGN); IN(accDmg, G_ACCDMG); IN(lastTile, G_LASTTILE);
    IN(lastPlotW, G_PLOTW); IN(fireImm, G_FIREIMM); IN(doorTimer, G_DOORTIMER);
    IN(quake, G_QUAKE); IN(shipMoving, G_SHIPMOVING); IN(radImm, G_RADIMM); IN(whistle1, G_WHISTLE1); IN(whistle2, G_WHISTLE2);
    IN(chatterRes, G_CHATTERRES); IN(eastOf76, G_EASTOF76);
    for (i = 0; i < 4; i++) { g->clawAvail[i] = (int)game[G_CLAWAVAIL0 + i]; g->clawTel[i] = (int)game[G_CLAWTEL0 + i]; }
    for (i = 0; i < 5; i++) g->gifts[i] = (int)game[G_GIFT0 + i];
    g->mode = 0x20;
    g->nSnd = 0;                                  /* the tick's sounds start empty */
    g->cross[1] = 0;
    for (i = 0; i < 8; i++) g->wl[i] = (int)game[G_WL0 + i];
    for (i = 0; i < 4; i++) g->rnd[i] = (int)game[G_RND0 + i];
    for (i = 0; i < 10; i++) g->scr[i] = (int)game[G_SCR0 + i];
    for (i = 0; i < 39; i++) g->kh[i] = (int)game[G_KH0 + i];
    for (i = 0; i < 19; i++) g->collected[i] = (int)game[G_COLL0 + i];
    for (i = 0; i < 235; i++) g->tert[i] = (int)game[G_TERT0 + i];
    {
        int lo, hi;
        if (g->feedMode) {
            /* the tick's record: keys, water level, screen position, the &d4 temporary, then the draws */
            const int *f = (const int *)feed;
            int pos = g->feedPos, n;
            lo = f[pos]; hi = f[pos + 1]; pos += 2;
            for (i = 0; i < 8; i++) { int v = f[pos++]; if (!g->eventsOn) g->wl[i] = v; }
            /* the screen the game had at the end of this tick, kept only to check
               the kernel's own against: the kernel works it out itself now, and
               during an object's update the origin is still the previous tick's */
            for (i = 0; i < 10; i++) g->fedScr[i] = f[pos++];
            g->relTY = f[pos++];
            n = f[pos++];
            g->feedPos = pos;
            g->feedEnd = pos + 2 * n;
        } else {
            lo = (int)(game[G_KMASK] & 0xFFFFFFFF); hi = (int)(game[G_KMASK] >> 32);
            g->feedEnd = 0;
        }
        for (i = 0; i < 39; i++) {
            int held = i < 32 ? (lo >> i) & 1 : (hi >> (i - 32)) & 1;
            g->kh[i] = (g->kh[i] >> 1) | (held << 7);
        }
    }
    g->whistle1 >>= 1;                            /* main_game_loop: the whistles last one tick */
    g->frm = (g->frm + 1) & 255;
    for (i = 0; i < NSLOT; i++) {
        if (OT(O_Y, i) == 0) continue;
        update_object(g, i);
    }
    if (g->eventsOn) {
        struct P pe;
        int *q = (int *)&pe, j;
        for (j = 0; j < (int)(sizeof(pe) / sizeof(int)); j++) q[j] = 0;
        pe.touch = 0xFF;
        update_events(g, &pe);
    }
    if (g->feedMode) {
        /* nothing the game's plotting did may be left over: a tile the kernel
           failed to look at would otherwise pass unnoticed, since read_site
           scans forward over what it does not model */
        const int *f = (const int *)feed;
        for (i = g->feedPos; i < g->feedEnd; i += 2)
            if (f[i] == SITE_TILE && (f[i + 1] & 0x800000)) { fault(g, 16, f[i + 1] & 0xFFFF); break; }
        g->feedPos = g->feedEnd;
    }
    /* the main loop after update_objects: the mushroom timers run down and the explosion timer runs up */
    if (g->blueMush) g->blueMush = (g->blueMush - 1) & 255;
    if (g->redMush) g->redMush = (g->redMush - 1) & 255;
    if (g->expTimer) g->expTimer = (g->expTimer + 1) & 255;
#define OUT(field, idx) game[idx] = g->field
    OUT(frm, G_FRAME); OUT(angle, G_ANGLE); OUT(facing, G_FACING); OUT(immob, G_IMMOB); OUT(tImmob, G_TIMMOB);
    OUT(rotVel, G_ROTVEL); OUT(lying, G_LYING); OUT(aim, G_AIM); OUT(aimVel, G_AIMVEL); OUT(aimFlip, G_AIMFLIP);
    OUT(jetOk, G_JETOK); OUT(inWater, G_INWATER); OUT(tbColl, G_TBCOLL); OUT(surr, G_SURR); OUT(wedged, G_WEDGED);
    OUT(signs, G_SIGNS); OUT(windSign, G_WINDSIGN); OUT(relTX, G_RELTX); OUT(relTY, G_RELTY); OUT(walkSpd, G_WALKSPD);
    OUT(maxAcc0, G_MAXACC0); OUT(fireCool, G_FIRECOOL); OUT(waterTile, G_WATERTILE);
    OUT(weapon, G_WEAPON); OUT(fired, G_FIRED); OUT(blaster, G_BLASTER); OUT(pockUsed, G_POCKUSED);
    OUT(orgF[0], G_ORGXF); OUT(orgF[2], G_ORGYF); OUT(frac[0], G_FRACX); OUT(sgn[0], G_SGNX);
    OUT(frac[2], G_FRACY); OUT(sgn[2], G_SGNY); OUT(secs[0], G_SECSX); OUT(secs[2], G_SECSY);
    OUT(sVel[0], G_SVELX); OUT(sVel[2], G_SVELY); OUT(newTiles, G_NEWTILES);
    OUT(secMode, G_SECMODE); OUT(secNext, G_SECNEXT); OUT(secShuf, G_SECSHUF); OUT(secDist, G_SECDIST);
    game[G_NPART] = g->nPart & 255;
    game[G_NSND] = g->nSnd;
    for (i = 0; i < 4; i++) game[G_WLDES0 + i] = g->wlDes[i];
    OUT(telRem, G_TELREM); OUT(telNext, G_TELNEXT); OUT(scrollX, G_SCROLLX); OUT(scrollY, G_SCROLLY); OUT(retrieve, G_RETRIEVE);
    for (i = 0; i < 6; i++) { game[G_WLO0 + i] = g->wLo[i]; game[G_WHI0 + i] = g->wHi[i]; }
    for (i = 0; i < 5; i++) { game[G_POCKET0 + i] = g->pocket[i]; game[G_TELX0 + i] = g->telX[i]; game[G_TELY0 + i] = g->telY[i]; }
    OUT(cross[0], G_CROSSX); OUT(cross[2], G_CROSSY); OUT(feedPos, G_FEEDPOS); OUT(held, G_HELD); OUT(demat, G_DEMAT);
    OUT(heldColl, G_HELDCOLL); OUT(preAng, G_PREANG); OUT(preMag, G_PREMAG); OUT(viewpoint, G_VIEWPOINT);
    OUT(fault, G_FAULT); OUT(faultArg, G_FAULTARG);
    OUT(tgt[0], G_TGTX); OUT(tgt[1], G_TGTXF); OUT(tgt[2], G_TGTY); OUT(tgt[3], G_TGTYF);
    OUT(wlBlock, G_WLBLOCK); OUT(doorSup, G_DOORSUP); OUT(routeBest, G_ROUTEBEST);
    OUT(expTimer, G_EXPTIMER); OUT(blueMush, G_BLUEMUSH); OUT(redMush, G_REDMUSH);
    OUT(accPower, G_ACCPOWER); OUT(accSign, G_ACCSIGN); OUT(accDmg, G_ACCDMG); OUT(lastTile, G_LASTTILE);
    OUT(lastPlotW, G_PLOTW); OUT(doorTimer, G_DOORTIMER);
    OUT(quake, G_QUAKE); OUT(shipMoving, G_SHIPMOVING); OUT(whistle1, G_WHISTLE1); OUT(whistle2, G_WHISTLE2);
    OUT(chatterRes, G_CHATTERRES); OUT(eastOf76, G_EASTOF76); OUT(flood, G_FLOOD);
    for (i = 0; i < 4; i++) { game[G_CLAWAVAIL0 + i] = g->clawAvail[i]; game[G_CLAWTEL0 + i] = g->clawTel[i]; }
    for (i = 0; i < 5; i++) game[G_GIFT0 + i] = g->gifts[i];
    for (i = 0; i < 8; i++) game[G_WL0 + i] = g->wl[i];
    for (i = 0; i < 4; i++) game[G_RND0 + i] = g->rnd[i];
    for (i = 0; i < 10; i++) game[G_SCR0 + i] = g->scr[i];
    for (i = 0; i < 39; i++) game[G_KH0 + i] = g->kh[i];
    for (i = 0; i < 19; i++) game[G_COLL0 + i] = g->collected[i];
    for (i = 0; i < 235; i++) game[G_TERT0 + i] = g->tert[i];
    return 0;
}
