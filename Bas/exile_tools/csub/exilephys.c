/* exilephys.c - the player's physics from Exile as a PicoMite CSUB.
 *
 * A function-for-function translation of Bas/exile_tools/exilephys.py, which
 * is the game's update_object (&1a17) for the player at the 8-bit level.
 * Every quantity is the byte the 6502 holds, and cy/ov are its carry and
 * overflow, so the result can be checked tick for tick against the game.
 *
 * Called from BASIC as
 *     ExileUpdate st(), world(), tbl()
 * where st() is the state array laid out by exilestate.h (one 64-bit
 * element per variable; the keys held this tick go in as a mask), world()
 * holds the 65,536 tile bytes of world_types.bin and tbl() the packed
 * tables of tables.bin.  One call is one tick of the player.
 *
 * A CSUB has no writable static data, so the state is copied into a struct
 * on the stack, worked on, and copied back.  32-bit integer arithmetic only,
 * as Cortex-M0+ code must be.
 */
#include "exilestate.h"

typedef unsigned char u8;

struct P {
    const u8 *world, *tab;
    int ps[3], pf[3], vel[3], acc[3], siz[3], mxp[3], mxf[3], cross[3], vec[3], qps[3], qpf[3], obs[4];
    int flags, spr, pal, energy, state, timer, touch, weight, typeFlags, palDefault;
    int frm, fc, fc16, kh[39], angle, facing, immob, tImmob, rotVel, lying, aim, aimVel, aimFlip;
    int jetOk, inWater, tbColl, surr, wedged, signs, windSign, relTX, relTY, walkSpd, maxAcc0, npcW0;
    int fireCool, waterTile, jetLo, jetHi, suitHi, boosterCol, suitCol;
    int wl[8], wlFrac, wlRow;
    int aimAccT, objCY, objCX, preMag, preAng, child, tileAng, upright, cYF, cYS, anyB, collTop;
    int tileX, tileY, tYoff, tFlip, tAddr, bYoff, bFlip, bAddr, topR, botR, waterline, mag, xFlip, yFlip, xFlipP;
    int cy, ov, rc, mxCarry, vecA;
    int feedMode, feedN, feedI, feedA[3], feedV[3];
    int rnd[4];
    int fault, faultArg;
};

#define DAMAGE_OBJECT 0x24A6
#define CHECK_RELIABILITY 0x2D92
#define REDUCE_WEAPON_ENERGY 0x2D79

/* ---- 8-bit helpers ------------------------------------------------------ */

static inline int u8v(int v) { return v & 255; }
static inline int neg8(int a) { return (-a) & 255; }
static inline int negative(int a) { return (a & 128) != 0; }
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

/* the game's random generator, for when no feed is supplied; the feed is how
   the test hands over the bytes the real game happened to read */
static int rnd_advance(struct P *p)
{
    int a = 0;
    a = (a + p->rnd[3]) & 255;
    a = (a + p->rnd[0]) & 255; p->rnd[0] = a;
    a = (a + p->rnd[2]) & 255; p->rnd[2] = a;
    a = (a + p->rnd[1]) & 255; p->rnd[1] = a;
    a = (a + p->rnd[3]) & 255; p->rnd[3] = a;
    return a;
}

static int read_at(struct P *p, int where)
{
    if (p->feedMode) {
        if (p->feedI >= p->feedN) { p->fault = 1; p->faultArg = where; return 0; }
        if (p->feedA[p->feedI] != where) { p->fault = 2; p->faultArg = where; return 0; }
        return p->feedV[p->feedI++];
    }
    if (where == REDUCE_WEAPON_ENERGY) return 0;     /* the drain takes two, the common case */
    return p->rnd[1];
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
    int xi, t;
    p->mxCarry = p->cross[0] & 1;
    for (xi = 2; xi >= 0; xi -= 2) {
        t = p->siz[xi] + p->pf[xi];
        p->mxf[xi] = t & 255;
        p->mxp[xi] = (p->ps[xi] + (t >> 8)) & 255;
        p->cross[xi] = ((t >> 8) << 7) | (p->cross[xi] >> 1);
    }
}

static void get_waterline(struct P *p, int x)
{
    int xi = 4;
    do { xi--; } while (x < p->tab[T_WLX + xi]);
    p->wlFrac = p->wl[xi]; p->wlRow = p->wl[4 + xi];
    if (p->wlRow * 256 + p->wlFrac > p->wl[5] * 256 + p->wl[1]) { p->wlFrac = p->wl[1]; p->wlRow = p->wl[5]; }
}

/* ---- tiles ----------------------------------------------------------------- */

static void weighted_accel(struct P *p, int desired, int yy, int xi, int maxacc);

static void wind_from_a(struct P *p, int a)
{
    int xi, yy;
    p->vec[0] = (a << 4) & 255; p->vec[2] = a;
    for (xi = 2; xi >= 0; xi -= 2) {
        yy = p->weight;
        if (yy < 4) yy++;
        if (p->waterline & 128) yy++;
        if ((p->inWater & 128) && !(p->frm & 0x10)) return;
        weighted_accel(p, p->vec[xi], yy, xi, 0x0C);
    }
}

static void tile_effect(struct P *p, int t, int flp)
{
    int wv;
    if (t >= 0x10 || !(p->tab[T_RTFLAGS + t] & 0x20)) return;
    if (t == 0x0D) {
        wv = p->tab[T_WATERVEL + (((flp >> 7) << 1) | ((flp >> 6) & 1))];
        if (wv) wind_from_a(p, wv);
        else p->waterTile = 128 | (p->waterTile >> 1);
    } else if (!p->fault) { p->fault = 3; p->faultArg = t; }
}

static void set_obs_vars(struct P *p, int which)
{
    int v = p->world[p->tileY * 256 + p->tileX];
    int t = v & 0x3F, flp = v & 0xC0, yo, h, q, fl, a, addr;
    tile_effect(p, t, flp);
    yo = p->tab[T_YOFF + t];
    if (flp & 0x40) yo = (yo << 4) & 255;
    yo &= 0xF0;
    if (yo) yo |= 0x0F;
    h = flp >> 7; q = (flp << 1) & 255;
    fl = q ^ p->tab[T_SPRF + t];
    a = ((p->tab[T_PAT + t] << 1) | h) & 255;
    a = ((a << 1) | (q >> 7)) & 0x3F;
    addr = p->tab[T_OBOFF + a];
    if (which == 0) { p->tYoff = yo; p->tFlip = fl; p->tAddr = addr; }
    else { p->bYoff = yo; p->bFlip = fl; p->bAddr = addr; }
}

static inline int pattern(struct P *p, int addr, int s) { return p->tab[T_OBPAT + addr + s]; }

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
    int a, a2 = 0, a3 = 0;
    a = add8(p, pattern(p, p->tAddr, yy), p->tYoff, 0);
    if (p->cy) a = 255;
    a = sub8(p, a, p->topR, 1);
    if (p->cy) { if (a >= p->siz[2]) a = p->siz[2]; a2 = a; }
    a = p->siz[2];
    if (p->cross[2] & 128) {
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

static void halve_clear(struct P *p)
{
    p->ps[0] = p->qps[0]; p->ps[2] = p->qps[2]; p->pf[0] = p->qpf[0]; p->pf[2] = p->qpf[2];
    p->vel[0] = asr(p, p->vel[0]); p->vel[2] = asr(p, p->vel[2]);
    maxima(p);
    p->rc = p->mxCarry;
    p->cYF = p->cYS = p->surr = 255;
    p->obs[0] = p->obs[1] = p->obs[2] = p->obs[3] = 0;
}

static int absc(struct P *p, int v)
{
    int c = v <= 0x7F, a = c ? v : ((v ^ 255) + 1) & 255;
    p->signs = ((p->signs << 1) | c) & 255;
    return a;
}

static int angle_from_vec(struct P *p)
{
    int ay = absc(p, p->vec[2]), ax = absc(p, p->vec[0]);
    int m = ay, a = ax, c = a >= m, ang = 8;
    if (c) { a = m; m = ax; }
    p->signs = ((p->signs << 1) | c) & 255;
    for (;;) {
        a = (a << 1) & 255;
        if (a >= m) { a = (a - m) & 255; c = 1; } else c = 0;
        ang = (ang << 1) | c;
        if (ang & 256) { ang &= 255; break; }
    }
    p->mag = m;
    return ang ^ p->tab[T_HALFQ + (p->signs & 7)];
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
    int a, c, yy, xi, n, angl;
    p->tileAng = angle_from_vec(p);
    a = sub8(p, p->tileAng, 0x60, 1);
    yy = (a & 0xC0) >> 6;
    xi = yy ^ 2;
    a = p->obs[yy];
    if (a < p->obs[xi]) a = p->obs[xi];
    if (a == 0) a = 0xFE;
    a = (a << 2) & 255;
    yy = (yy - 1) & 255;
    xi = (yy & 1) << 1;
    if (xi == 0) { a = add8(p, a, 0x0F, 1); if (p->cy) a = 0xFE; }
    /* CPY #2 ; BCC ; INY ; PHP: N comes from the INY for top and left */
    n = (yy < 2) ? 1 : (((yy + 1) & 128) != 0);
    if (!n) a = neg8(a);
    add_to_pos(p, xi, a, n);
    maxima(p);
    p->vec[0] = p->vel[0]; p->vec[2] = p->vel[2];
    p->preAng = angle_from_vec(p); p->preMag = p->mag;
    a = sub8(p, p->preAng, p->tileAng, 1); c = p->cy;
    angl = a;
    if (!(a & 128)) {
        a = sub8(p, a, 0x3F, 1);
        a = asr(p, a); a = asr(p, a); a = asr(p, a); c = p->cy;
        a = add8(p, a, angl, c);
        a ^= 255;
        angl = add8(p, a, p->tileAng, 1);
        a = p->preMag;
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
        else if (p->preMag < 0x40) p->rc = 0;
        else halve_clear(p);
    }
}

static void coll_tiles(struct P *p)
{
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
            if (p->cross[2] & 128) { p->tileY = (p->tileY - 1) & 255; set_obs_vars(p, 0); }
            else { p->tYoff = p->bYoff; p->tAddr = p->bAddr; p->tFlip = p->bFlip; }
            yy = 0;
            break;
        }
        if (done) break;
    }
    bot = (bot << 3) & 255; top = (top << 3) & 255;
    a = sub8(p, top, bot, 1);
    p->vec[0] = a; p->vec[2] = 0;
    p->cYS = a;
    p->cYF = ((a ^ 255) + 1) & 255;
    c = (bot | top) >= 1;
    p->tbColl = (c << 7) | (p->tbColl >> 1);
    rgt = check_tb(p, yy);
    a = sub8(p, rgt, lft, 1); c = p->cy;
    p->vec[2] = a;
    p->obs[0] = lft; p->obs[1] = top; p->obs[2] = rgt; p->obs[3] = bot;
    if ((a | p->vec[0]) != 0) tile_collision(p);
    else if ((lft | top) == 0) p->rc = c;
    else halve_clear(p);
}

static void coll_water_tiles(struct P *p)
{
    int a, a2, xi, tw, yy, h4, c, c2, old;
    p->surr >>= 1;
    a = sub8(p, p->mxf[2], p->wlFrac, 1); xi = a; c = p->cy;
    a2 = sub8(p, p->mxp[2], p->wlRow, c); c2 = p->cy;
    if (a2 != 0) xi = c2 ? 255 : 0;
    p->waterline = xi;
    p->tileX = p->ps[0]; p->tileY = p->ps[2];
    xi = 0; p->waterTile = 0;
    set_obs_vars(p, 0);
    c = p->waterTile >> 7; p->waterTile = (p->waterTile << 1) & 255;
    if (c) xi = 255;
    if (p->cross[2] & 128) {
        p->tileY = (p->tileY + 1) & 255;
        set_obs_vars(p, 1);
        c = p->waterTile >> 7; p->waterTile = (p->waterTile << 1) & 255;
        if (c) xi |= p->mxf[2];
    } else { p->bYoff = p->tYoff; p->bAddr = p->tAddr; p->bFlip = p->tFlip; }
    if (xi < p->waterline) xi = p->waterline;
    tw = xi;
    yy = p->weight; if (yy == 0) yy = 1;
    h4 = p->siz[2] >> 2;
    xi = 4; a = tw;
    c = a ? 0 : 1;
    old = p->inWater; p->inWater = (c << 7) | (old >> 1); c = old & 1;
    if (!(p->inWater & 128)) {
        for (;;) {
            a = sub8(p, a, h4, c); c = p->cy;
            if (!c) break;
            yy = (yy - 1) & 255;
            if (yy & 128) p->vel[2] = (p->vel[2] - 1) & 255;
            else if (yy == 0) p->vel[2] = (p->vel[2] - 2) & 255;
            if (--xi == 0) break;
        }
        if (p->frm % 4 == 0) { p->vel[0] = seven_eighths(p->vel[0]); p->vel[2] = seven_eighths(p->vel[2]); }
    }
    coll_tiles(p);
}

/* ---- damage and the surface wind ---------------------------------------------- */

static int damage_without_destroying(struct P *p, int dmg)
{
    int da = read_at(p, DAMAGE_OBJECT), i, c, old, a;
    if (!(da & 128)) {
        p->lying >>= 1;
        if (dmg >= p->immob) p->immob = dmg;
    }
    for (i = 0; i < 3; i++) { c = dmg >> 7; dmg = (dmg << 1) & 255; if (c) dmg = (dmg >> 1) | 128; }
    old = p->energy;
    a = sub8(p, old, dmg, 1);
    if (!p->cy) a = 0;
    if (a == 0 && old != 0) a = 1;
    return a;
}

static void surface_wind(struct P *p)
{
    int a, c, xi = 2, yy;
    p->vec[0] = p->vec[2] = 0;
    a = sub8(p, p->ps[2], 0x4E, 0); c = p->cy;
    for (;;) {
        yy = (p->weight + 1) & 255;
        p->windSign = (c << 7) | (p->windSign >> 1);
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
            if (p->windSign & 128) a = neg8(a);
            p->vec[xi] = a;
            weighted_accel(p, p->vec[xi], yy, xi, 0x0C);
            c = p->rc;
        }
        a = sub8(p, p->ps[0], 0x9B, c); c = p->cy;
        xi -= 2;
        if (xi != 0) break;
    }
}

/* ---- update_player (&4a11) ----------------------------------------------------- */

static void handle_jumping(struct P *p)
{
    int a, c;
    if ((p->state & 15) >= 5) return;
    a = (p->kh[0x15] & 128) ? 0xF0 : 0xF6;
    a = add8(p, a, p->weight, 0);
    c = a >> 7; a = (a << 1) & 255;
    p->vel[2] = add8(p, a, p->vel[2], c);
    p->upright >>= 1;
}

static void use_booster(struct P *p)
{
    if (!((p->jetOk & p->boosterCol) & 128)) return;
    if (!(p->acc[2] & 128) && p->acc[0] != 0) p->state |= 15;
    p->acc[0] = (p->acc[0] << 1) & 255; p->acc[2] = (p->acc[2] << 1) & 255;
}

static void do_action(struct P *p, int i)
{
    if (i == 34) p->acc[0] = (p->acc[0] + 1) & 255;                 /* W: thrust right */
    else if (i == 33) p->acc[0] = (p->acc[0] - 1) & 255;            /* Q: thrust left */
    else if (i == 37) p->acc[2] = (p->acc[2] + 1) & 255;            /* L: thrust down */
    else if (i == 35) {                                             /* P: thrust up, and fly */
        p->acc[2] = (p->acc[2] - 1) & 255;
        if (p->jetOk & 128) p->state |= 15;
    }
    else if (i == 36) handle_jumping(p);                            /* P once: jump */
    else if (i == 21) use_booster(p);                               /* @: booster */
    else if (i == 22) p->state |= 15;                               /* CTRL: lie down */
    else if (i == 23) p->facing ^= 128;                             /* TAB: turn round */
    else if (i == 14) { p->aim = p->aimVel = 0; p->aimAccT = (p->aimAccT - 1) & 255; }   /* I: centre the aim */
    else if (i == 20) p->aimAccT = (p->aimAccT - 1) & 255;          /* O: raise the aim */
    else if (i == 19) p->aimAccT = (p->aimAccT + 1) & 255;          /* K: lower the aim */
    else if (!p->fault) { p->fault = 4; p->faultArg = i; }
}

static void process_actions(struct P *p)
{
    int i, k;
    for (i = 0x26; i >= 0; i--) {
        k = p->kh[i];
        if (!(k & 128)) continue;
        if ((k & 0xC0) == 0xC0 && p->tab[T_NOREPEAT + i]) continue;
        do_action(p, i);
    }
}

static int check_reliability(struct P *p, int xi)
{
    int da = read_at(p, CHECK_RELIABILITY), hi = xi == 0 ? p->jetHi : p->suitHi, c, a, i, nc;
    if (hi >= 4) return 1;
    c = xi == 0;
    a = hi;
    for (i = 0; i < 3; i++) { nc = a & 1; a = (c << 7) | (a >> 1); c = nc; }
    return a >= da;
}

static void drain_jetpack(struct P *p)
{
    int c = read_at(p, REDUCE_WEAPON_ENERGY), lo, hi;
    lo = sub8(p, p->jetLo, p->tab[T_WEAPONCOST + 0], c); c = p->cy;
    hi = sub8(p, p->jetHi, 0, c);
    if (!p->cy) { hi = 0; lo = 0; }
    p->jetLo = lo; p->jetHi = hi;
}

static void rotating_player(struct P *p)
{
    int a, a2, c, hit = 0, n;
    p->immob = (p->immob - 1) & 255;
    a2 = (p->angle << 1) & 255;
    if (p->tbColl & 128) { a = p->preAng; hit = 1; }
    else if (p->touch & 128) a = p->rotVel;
    else { a = 0x40; hit = 1; }
    if (hit) {
        a = (a << 1) & 255;
        a = sub8(p, a, a2, 1); c = p->cy;
        a = (c << 7) | (a >> 1);
        n = a & 128;
        a = (p->preMag >> 2) | 1;
        if (n) a = neg8(a);
        a = add8(p, a, p->rotVel, 0);
        a = keep_range(a, 0x20);
    }
    if (p->frm % 4 == 0 && a >= 4 && a < 0xFD) a = seven_eighths(a);
    p->rotVel = a;
    p->angle = (p->angle + a) & 255;
}

static void angle_and_facing(struct P *p)
{
    int xi, c = 0, a, yy, kept = 0;
    p->vec[0] = p->acc[0]; p->vec[2] = p->acc[2];
    xi = ((p->acc[2] != 0) << 1) | (p->acc[0] != 0);
    if (xi != 0 && (p->jetOk & 128)) { a = angle_from_vec(p); c = 1; }
    else {
        a = 0xC0;
        if (p->lying & 128) a = (p->facing & 128) ? 0x83 : 0xFD;
    }
    a = sub8(p, a, p->angle, c);
    yy = a;
    if (xi == 2) {
        a = sub8(p, a, 0x74, 1);
        if (a < 0x18) { yy = 0; xi = 0; kept = 1; }
    }
    if (!kept && (p->acc[0] == 0 || !(p->upright & 128))) xi = 0;
    c = jumping(p);
    a = yy;
    if (!c && !(p->lying & 128)) a = 0;
    a = asr(p, a); a = asr(p, a); c = p->cy;
    p->angle = add8(p, a, p->angle, c);
    a = p->angle ^ p->acc[0] ^ 128;
    if (!(((xi - 1) & 255) & 128)) p->facing = a;
}

static int walk_state(struct P *p)
{
    int c = 1, a;
    if (!(p->upright & 128)) { p->state |= 15; return p->state; }
    if ((p->tbColl | p->objCY) & 128) c = inv_neg(p->tileAng) >= 0x32;
    a = p->state & 0xF0;
    if (!c) { p->state = a; return p->state; }
    if ((a ^ p->state) < 15) p->state = (p->state + 1) & 255;
    return p->state;
}

static void walk_along(struct P *p, int spd, int yy, int maxacc)
{
    int a, c, accl, angl;
    a = (p->relTX & 128) ? neg8(spd) : spd;
    a = sub8(p, a, p->vel[0], 1);
    accl = weight_limit(p, a, p->cy, p->ov, yy, maxacc);
    a = (accl & 128) ^ p->tileAng;
    a = add8(p, a, 0x40, 0);
    c = a >> 7;
    if (p->relTX == 0) accl = 0;
    if (!c) angl = add8(p, 0x10, p->tileAng, 0); else angl = add8(p, 0x6F, p->tileAng, 1);
    vec_from_mag_angle(p, inv_neg(accl), angl);
    p->acc[2] = p->vecA; p->acc[0] = p->vec[0];
    p->vel[2] = seven_eighths(seven_eighths(p->vel[2]));
}

static void climb_steep(struct P *p, int spd, int yy, int maxacc)
{
    int a = (p->relTY & 128) ? neg8(spd) : spd;
    weighted_accel(p, a, yy, 2, maxacc);
    p->acc[0] = (p->tileAng & 128) ? 8 : 0xF8;
    p->vel[0] = seven_eighths(seven_eighths(seven_eighths(p->vel[0])));
}

static void walk_player(struct P *p)
{
    int a, c, maxacc, yy, spd;
    a = walk_state(p);
    if (a & 15) return;
    maxacc = p->maxAcc0; yy = p->npcW0;
    a = inv_neg(p->tileAng);
    c = a >= 0x32;
    a = sub8(p, a, 0x2C, c);
    c = a >= 0x28;
    spd = p->walkSpd;
    if (!c) climb_steep(p, spd, yy, maxacc); else walk_along(p, spd, yy, maxacc);
}

static void update_walking(struct P *p)
{
    int c, yy, a;
    p->walkSpd = 0x1F;
    c = p->fc16 >= 2;
    yy = sub8(p, p->weight, 5, c); c = p->cy;
    if (c && jumping(p) && !(p->anyB & 128)) {
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
    p->relTX = p->acc[0];
    if (p->acc[0] == 0) { p->walkSpd = 0; a = 1; }
    p->maxAcc0 = a;
    if (!jumping(p)) p->acc[0] = 0;
    walk_player(p);
}

static void change_sprite(struct P *p, int a)
{
    int d, c;
    if (a == p->spr) return;
    p->spr = a;
    d = sub8(p, p->siz[2], p->tab[T_SPRH + a], 1); c = p->cy;
    d = ((c << 7) | (d >> 1)) ^ 128;
    add_to_pos(p, 2, d, d & 128);
    d = sub8(p, p->siz[0], p->tab[T_SPRW + a], 1); c = p->cy;
    d = ((c << 7) | (d >> 1)) ^ 128;
    add_to_pos(p, 0, d, d & 128);
}

static int sprite_offset(struct P *p, int modulus)
{
    int a = inv_neg(p->vel[0]), b = inv_neg(p->vel[2]), c;
    if (b > a) a = b;
    a >>= 4;
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
    a = sprite_offset(p, 8);
    stg = a >> 1;
    if ((p->vel[0] ^ p->xFlip) & 128) stg ^= 3;
    change_sprite(p, (stg + 4) & 255);
}

static void sprite_and_palette(struct P *p, int a, int yy)
{
    int flsh, pal, c, t;
    if (!(p->child & 128)) { p->xFlipP = yy; sprite_from_angle(p, a); }
    flsh = (((p->fc & 0x1F) << 1) & 255) >= p->energy;
    pal = p->palDefault;
    c = check_reliability(p, 5);
    t = ((c << 7) | (pal >> 1)) & p->suitCol;
    pal = (t & 128) ? 0x33 : 0x3E;
    if (flsh) pal = p->pal ^ 0x0B;
    p->pal = pal;
}

static void angle_facing_sprite(struct P *p)
{
    int a, c, old, ax, ay, drain = 1;
    p->acc[0] = (p->acc[0] << 1) & 255;
    c = p->acc[2] >> 7; p->acc[2] = (p->acc[2] << 1) & 255;
    if (p->frm % 16 == 0) {
        a = add8(p, p->energy, 4, c);
        if (!p->cy) p->energy = a;
        c = check_reliability(p, 0);
        old = p->jetOk; p->jetOk = (c << 7) | (old >> 1); c = old & 1;
    }
    a = sub8(p, 0x10, p->energy, c);
    if (p->cy) p->immob = a;
    if (p->immob >= 6) p->jetOk >>= 1;
    if (p->tImmob) { p->tImmob = (p->tImmob - 1) & 255; p->jetOk >>= 1; }
    p->lying >>= 1;
    a = sub8(p, p->angle, 0xCF, 1); c = a >= 0xE1;
    p->upright = ((c << 7) | (a >> 1)) & p->upright;
    ax = p->acc[0]; ay = p->acc[2];
    if (ay == 0) {
        if (ax == 0) p->lying = p->surr | p->wedged | p->kh[0x16];
        if (jumping(p)) {
            if (p->anyB & 128) p->vel[2] = seven_eighths(seven_eighths(seven_eighths(p->vel[2])));
        } else drain = 0;
    }
    if (drain && (p->jetOk & 128) && (p->acc[0] | p->acc[2]) != 0) {
        /* every_eight | booster key, masked by every_two */
        if (!(p->frm & 1) && ((p->frm & 7) == 0 || (p->kh[0x15] & 128))) drain_jetpack(p);
    }
    if (p->immob) rotating_player(p); else angle_and_facing(p);
    update_walking(p);
    if (!(p->jetOk & 128)) { p->acc[2] = 0; if (jumping(p)) p->acc[0] = 0; }
    sprite_and_palette(p, p->angle, p->facing);
}

static void aiming_angle(struct P *p)
{
    int a = p->aimAccT;
    if (a) { a = add8(p, a, p->aimVel, 0); a = keep_range(a, 0x10); }
    p->aimVel = a;
    a = add8(p, a, p->aim, 0);
    a = keep_range(a, 0x3F);
    p->aim = a;
    if (p->xFlip & 128) a = ((a ^ 0x7F) + 1) & 255;
    p->aimFlip = a;
}

static void update_player(struct P *p)
{
    if (!(p->touch & 128) && !p->fault) { p->fault = 5; p->faultArg = p->touch; }
    process_actions(p);
    if (!(p->flags & 0x10)) angle_facing_sprite(p);
    aiming_angle(p);
    p->fireCool = (p->fireCool - 1) & 255;
    if (p->fireCool == 0) p->kh[13] >>= 1;
}

static void apply_acceleration(struct P *p)
{
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
        if (p->frm % 16 == 0 && yy != 0) yy = (yy & 128) ? (yy + 1) & 255 : (yy - 1) & 255;
        p->vel[xi] = yy;
    }
}

/* ---- update_object (&1a17) --------------------------------------------------------- */

static void update_object(struct P *p)
{
    int a, c, prevFlags, flp;
    p->qps[0] = p->ps[0]; p->qps[2] = p->ps[2]; p->qpf[0] = p->pf[0]; p->qpf[2] = p->pf[2];
    prevFlags = p->flags;
    p->xFlip = p->flags; p->yFlip = (p->flags << 1) & 255;
    p->fc = p->frm; p->fc16 = p->frm & 15;
    get_waterline(p, p->ps[0]);
    p->weight = p->typeFlags & 7;
    p->siz[0] = p->tab[T_SPRW + p->spr] & 0xF0; p->siz[2] = p->tab[T_SPRH + p->spr] & 0xF8;
    p->acc[0] = p->acc[2] = 0; p->aimAccT = 0; p->objCY = p->objCX = 0; p->preMag = 0; p->child = 0; p->tileAng = 0;
    p->upright = 255;
    add_to_pos(p, 2, p->vel[2], p->vel[2] & 128);
    add_to_pos(p, 0, p->vel[0], p->vel[0] & 128);
    maxima(p);
    coll_water_tiles(p);
    c = p->rc;
    /* body collision damage */
    a = sub8(p, p->tileAng, p->angle, c); a = sub8(p, a, 0x40, p->cy);
    a = inv_neg(a); a >>= 1; c = a & 1; a >>= 1;
    a = add8(p, a, 0xC0, c); a = add8(p, a, p->preMag, p->cy);
    if (p->cy) p->energy = damage_without_destroying(p, a >> 1);
    /* support and wedging */
    p->anyB = p->cYF | p->objCY;
    p->collTop = ((p->objCY << 1) & 255) | p->cYS;
    p->wedged >>= 1;
    p->flags &= 0xFD;
    if (!(p->collTop & 128)) {
        if (p->anyB & 128) p->flags |= 2;
    } else if (prevFlags & 2) {
        p->wedged = 128 | (p->wedged >> 1);
        if (p->obs[2] != p->obs[0]) {
            a = 0x10;
            if ((p->obs[2] - p->obs[0]) & 128) a = 0xF0;
            add_to_pos(p, 0, a, a & 128);
            maxima(p);
        }
    }
    if (p->flags & 0x10) { if (!p->fault) p->fault = 6; }
    if (p->ps[2] < 0x4F) surface_wind(p);
    update_player(p);
    if (p->energy == 0 && !p->fault) p->fault = 7;
    apply_acceleration(p);
    flp = (p->xFlip & 128) | ((p->yFlip & 128) >> 1);
    p->flags = ((p->flags & 0xC0) ^ p->flags ^ flp) & 0xF3;
    p->touch |= 128;
    p->flags &= 0xFE;
}

/* ---- the CSUB entry: one tick --------------------------------------------------------- */

long long exile_update(long long *st, long long *world, long long *tab)
{
    struct P p;
    int i, kmask_lo, kmask_hi;
    p.world = (const u8 *)world;
    p.tab = (const u8 *)tab;
    p.fault = 0; p.faultArg = 0;
#define IN(field, idx) p.field = (int)st[idx]
    IN(ps[0], S_X); IN(pf[0], S_XF); IN(ps[2], S_Y); IN(pf[2], S_YF); IN(vel[0], S_VX); IN(vel[2], S_VY);
    IN(flags, S_FLAGS); IN(spr, S_SPRITE); IN(pal, S_PALETTE); IN(energy, S_ENERGY); IN(state, S_STATE);
    IN(timer, S_TIMER); IN(touch, S_TOUCHING); IN(frm, S_FRAME); IN(angle, S_ANGLE); IN(facing, S_FACING);
    IN(immob, S_IMMOB); IN(tImmob, S_TIMMOB); IN(rotVel, S_ROTVEL); IN(lying, S_LYING); IN(aim, S_AIM);
    IN(aimVel, S_AIMVEL); IN(aimFlip, S_AIMFLIP); IN(jetOk, S_JETOK); IN(inWater, S_INWATER); IN(tbColl, S_TBCOLL);
    IN(surr, S_SURR); IN(wedged, S_WEDGED); IN(signs, S_SIGNS); IN(windSign, S_WINDSIGN); IN(relTX, S_RELTX);
    IN(relTY, S_RELTY); IN(walkSpd, S_WALKSPD); IN(maxAcc0, S_MAXACC0); IN(npcW0, S_NPCW0); IN(fireCool, S_FIRECOOL);
    IN(waterTile, S_WATERTILE); IN(jetLo, S_JETLO); IN(jetHi, S_JETHI); IN(suitHi, S_SUITHI); IN(boosterCol, S_BOOSTERCOL);
    IN(suitCol, S_SUITCOL); IN(typeFlags, S_TYPEFLAGS); IN(palDefault, S_PALDEFAULT); IN(cross[0], S_CROSSX); IN(cross[2], S_CROSSY);
    IN(feedMode, S_FEEDMODE); IN(feedN, S_FEEDN);
    IN(preAng, S_PREANG); IN(preMag, S_PREMAG); IN(objCY, S_OBJCY);
    for (i = 0; i < 3; i++) { p.feedA[i] = (int)st[S_FEEDA0 + 2 * i]; p.feedV[i] = (int)st[S_FEEDV0 + 2 * i]; }
    for (i = 0; i < 8; i++) p.wl[i] = (int)st[S_WL0 + i];
    for (i = 0; i < 4; i++) p.rnd[i] = (int)st[S_RND0 + i];
    for (i = 0; i < 39; i++) p.kh[i] = (int)st[S_KH0 + i];
    p.feedI = 0;
    p.cross[1] = 0; p.ps[1] = p.pf[1] = p.vel[1] = p.acc[1] = p.siz[1] = p.mxp[1] = p.mxf[1] = p.vec[1] = 0;
    p.qps[1] = p.qpf[1] = 0;
    p.rc = p.cy = p.ov = p.mxCarry = p.vecA = p.mag = p.signs & 0;
    /* the interrupt: shift the key history and put "held now" in bit 7 */
    kmask_lo = (int)(st[S_KMASK] & 0xFFFFFFFF);
    kmask_hi = (int)(st[S_KMASK] >> 32);
    for (i = 0; i < 39; i++) {
        int held = i < 32 ? (kmask_lo >> i) & 1 : (kmask_hi >> (i - 32)) & 1;
        p.kh[i] = (p.kh[i] >> 1) | (held << 7);
    }
    p.frm = (p.frm + 1) & 255;
    if (!p.feedMode) rnd_advance(&p);          /* the tick's own draw, as update_events would */
    update_object(&p);
#define OUT(field, idx) st[idx] = p.field
    OUT(ps[0], S_X); OUT(pf[0], S_XF); OUT(ps[2], S_Y); OUT(pf[2], S_YF); OUT(vel[0], S_VX); OUT(vel[2], S_VY);
    OUT(flags, S_FLAGS); OUT(spr, S_SPRITE); OUT(pal, S_PALETTE); OUT(energy, S_ENERGY); OUT(state, S_STATE);
    OUT(timer, S_TIMER); OUT(touch, S_TOUCHING); OUT(frm, S_FRAME); OUT(angle, S_ANGLE); OUT(facing, S_FACING);
    OUT(immob, S_IMMOB); OUT(tImmob, S_TIMMOB); OUT(rotVel, S_ROTVEL); OUT(lying, S_LYING); OUT(aim, S_AIM);
    OUT(aimVel, S_AIMVEL); OUT(aimFlip, S_AIMFLIP); OUT(jetOk, S_JETOK); OUT(inWater, S_INWATER); OUT(tbColl, S_TBCOLL);
    OUT(surr, S_SURR); OUT(wedged, S_WEDGED); OUT(signs, S_SIGNS); OUT(windSign, S_WINDSIGN); OUT(relTX, S_RELTX);
    OUT(relTY, S_RELTY); OUT(walkSpd, S_WALKSPD); OUT(maxAcc0, S_MAXACC0); OUT(fireCool, S_FIRECOOL);
    OUT(waterTile, S_WATERTILE); OUT(jetLo, S_JETLO); OUT(jetHi, S_JETHI); OUT(cross[0], S_CROSSX); OUT(cross[2], S_CROSSY);
    OUT(feedI, S_FEEDI); OUT(fault, S_FAULT); OUT(faultArg, S_FAULTARG);
    OUT(preAng, S_PREANG); OUT(preMag, S_PREMAG); OUT(objCY, S_OBJCY);
    OUT(tileAng, S_TILEANG); OUT(anyB, S_ANYB); OUT(upright, S_UPRIGHT);
    for (i = 0; i < 4; i++) st[S_RND0 + i] = p.rnd[i];
    for (i = 0; i < 39; i++) st[S_KH0 + i] = p.kh[i];
    return 0;
}
