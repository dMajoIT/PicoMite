# Exile's sounds, and when you should hear them

The game has forty-eight sounds. Forty-five of them are in the port; the three
that are not are listed at the end.

## How they work, in one paragraph

Exile drives the BBC's sound chip itself rather than using the operating
system. Every fiftieth of a second its interrupt steps a volume envelope and a
frequency envelope for each of four channels and writes the chip's registers.
The port runs those same envelopes out of the game's own table and hands each
step to `PLAY BBC SOUND` as a flushed note, two steps to a game tick.

Two things decide whether you hear anything at all:

- **Nothing sounds from more than sixteen squares off the middle of the
  screen.** If you cannot see roughly where it happened, you will not hear it.
- **What is nearer the edge is quieter**, by sixteen steps of volume a square.

So a sound that seems to be missing may simply be too far away, and one that
seems faint is meant to be.

## The player's own actions

| What you hear | When |
|---|---|
| A low beep | Firing the plasma gun |
| A shot | Firing the pistol |
| A different shot | Firing the icer |
| A long discharge | The blaster, which goes on for five frames |
| A bullet going off | A pistol bullet striking something |
| A high beep | Dropping whatever you are holding |
| A high beep, then a warble | Blowing either whistle |
| A middle beep | Remembering your position |
| A rising tone | Teleporting back to it |
| A retrieval | Taking something back out of a pocket |
| A collect | Picking something up |
| A low beep | Something being absorbed |

The weapon sounds need a weapon. A new game has the jetpack selected, which
fires nothing, so space is silent until you have found one and picked it up
with a function key.

## Machinery

| What you hear | When |
|---|---|
| A lock turning | Firing the remote control device at a door or a transporter beam, while carrying the key of its colour |
| A door | Every time a door starts opening, and again when it starts closing |
| A switch | Pressing one |
| A second sound after it | Whatever that switch sets off, once for each thing it changes |
| A pulse | A power pod, two frames in sixteen, for as long as it lives |
| A slow pulse | The destinator, one frame in thirty-two |
| A single tone | The destinator the moment the ship leaves |
| A roar | An engine fire, on the one tick in four when it blows things about |
| A scrape | Moving the view on its own with the arrow keys |

## Creatures

| What you hear | When |
|---|---|
| A bird call | One time in sixty-four, per bird, per tick |
| A squeal | Fluffy, when it is hurt or frightened |
| A purr | Fluffy, when it is content and active |
| A mutter | A hovering robot, one time in a hundred and twenty-eight |
| A different mutter | A clawed robot, at the same odds |
| A chatter | A Chatter loosing its lightning |
| Two squeals together | A worm or a maggot, more often the nearer it is to the middle of the screen |
| A digging sound | Anything starting to burrow into ground it wants to dig |
| A hum | A hive letting one of its own out |
| A bite | A piranha or a wasp, only when it has just hurt you |
| A hiss | The sucking nest, every tick it has hold of something |
| A pop | A slime turning yellow after eating a coronium crystal |
| A crackle | A red drop burning whatever it lands on |
| A knock | A hovering ball hurting something |
| A fade | A hovering ball going back to its nest |
| A tick | An active grenade, once every sixteen frames |

## Things blowing up

| What you hear | When |
|---|---|
| A squeal, then an explosion | Most things, when their energy runs out |
| A louder squeal first | The kinds that die noisily |
| An explosion on its own | Anything else exploding |
| A rumble | The earthquake, once it has started |
| A soft thud | Touching a mushroom tile, and a mushroom ball bursting |

## The three that are not in yet

| What you should hear | When | Why it is missing |
|---|---|---|
| The player's scream | Taking heavy damage | Its trigger condition still needs working out |
| An imp's call | An imp about its business | The same, and its pitch is altered per imp |
| The energy level bell | As your energy crosses a level | The game keeps a count of bells still owed, which the port does not model yet |

None of the three can break anything by arriving later. A sound is put on a
queue that nothing inside the physics reads, so adding one cannot change how
the game plays.

## If something sounds wrong

The useful question is not "is this sound right" but "what is sounding". Tell
me roughly where you are standing and what you can see, and the state can be
replayed from that square with every sound recorded, which is how the last two
faults here were found. Reasoning about it from the code found the wrong
answer twice.
