# PixelLab prompts for the class avatars

Animation prompts for every pose of every class, written from the class notes, for trying PixelLab's animation
tools on the avatars. The shipped frames are in `app/Sources/App/Resources/Sprites/<class>/` on this branch.

## How to use them

**Tool.** Use PixelLab's image-to-animation tools, which start from a frame we already have: *Animate with text v3*
in the app (`animate-with-text-v3` in the API, `animate_image` in the MCP), or *PixMiniMax* (`animate-pixminimax`).
Both take a first frame up to 256x256 and an optional last frame; our largest canvas is 133x196 (paladin), so every
frame fits as it is. Avoid the older *Animate with text* (v1): it works only at 64x64.

**Frames.** Each pose below names its first frame. The files are the character layer only: the magic (glows,
circles, swirls, the "!" bubble) is drawn by the app in separate layers, so the prompts ask for none. Give a last
frame when you want in-betweens toward a pose we already have:

- **Entrance** (idle into the pose): first frame `01-idle-f1.png`, last frame the pose's `f1`. This is the open
  "in-between frames for entrances" item: today the body snaps into each pose.
- **Loop**: first frame the pose's `f1`; PixelLab's frame count must be even, so 4 frames is the closest to our
  2 to 4-frame loops.
- **Finish**: first frame the pose's `f1`, last frame `01-idle-f1.png` when the finish returns to idle.

**Fields.** For PixMiniMax, paste the class's *subject* into `subject_description` and the pose's *initial pose*
into `initial_pose`. Set the camera from the class line: view `low top-down` for every class; direction `south-east`
(turned a little toward the image's right) except the paladin, who faces the viewer (`south`).

**Rules every prompt follows** (from the playbook; add them to a prompt if a result breaks one):

- Feet stay planted on the same line. No hop, bob, bounce, lean or slide of the whole figure.
- Only the part the action names moves: a hand, the head, a prop. The rest of the body holds still.
- Props stay whole and the same size: the staff, the mace, the hammer, the lute, the axe, the daggers.
- No glow, sparks, particles or magic drawn on the frames: the app adds them.
- Small, slow moves for the wizard, the cleric and the paladin; graceful for the druid; lively for the bard; quick and
  quiet for the rogue.

A short negative line that covers most of them: `jumping, bobbing, leaning, walking, sliding, glowing effects,
particles, changing size, broken props, extra limbs`.

**Numbering.** 01 idle, 02 pondering, 03 studying, 04 inscribing, 05 channelling, 06 scrying, 07 signature
(spellsong for the files of every class), 08 release, 09 summoning, 10 catching, 11 calling out, 12 triumph (bow),
13 fizzle (no trigger yet; only the bard ships one).

---

## Wizard

- **Subject:** `an old wizard in a blue hood and robes, with a long grey beard and a gnarled wooden staff`
- **Camera:** low top-down, south-east. **Temperament:** old, elegant and wise; nothing thrust, flung or raised high.

| Pose | Initial pose | Prompts |
|---|---|---|
| 01 Idle | leaning on his staff with both hands | **Loop:** `breathing slowly, shoulders rising and falling slightly, one blink` · **Fidget 1:** `raises one hand to adjust the edge of his hood, then lowers it` · **Fidget 2:** `lifts the staff a little and taps its foot on the ground once` |
| 02 Pondering | both hands on the staff, gazing up in thought | **Loop:** `gazes upward, his brows lift slowly and settle` |
| 03 Studying | a spellbook floating open in front of him, the staff in his near arm, the far hand at his beard | **Loop:** `strokes his beard slowly downward with his free hand, a page of the floating book turns` · **Finish:** `the floating book snaps shut, his hand lowers from his beard` |
| 04 Inscribing | holding the staff forward, tracing in the air with its tip | **Loop:** `traces small strokes in the air with the staff's tip, the staff stays whole` · **Finish:** `lowers the staff tip back to rest` |
| 05 Channelling | staff held slightly forward | **Loop:** `his free hand lifts slowly toward the staff and lowers again` · **Finish:** `lowers the staff a little and relaxes his free hand` |
| 06 Scrying | gazing into the crystal at the staff's head | **Loop:** `passes his free hand slowly over the staff's head, palm down` · **Finish:** `lowers his free hand and looks away from the crystal` |
| 07 Arcane weaving | free hand held open in front of him | **Loop:** `turns his open hand slowly, fingers spreading` · **Finish:** `closes his hand gently` |
| 08 Release | staff tipped forward | **One-shot:** `tips the staff forward toward the right in one smooth motion, then holds` |
| 09 Summoning | staff held slightly in front of him, a little raised, gaze up | **One-shot:** `raises the staff a little higher, looking upward` |
| 10 Catching | free hand open | **One-shot:** `opens his free hand palm up and draws it slightly toward his chest` |
| 11 Calling out | free hand raised to shoulder height | **Loop:** `waves his raised hand slowly side to side once` |
| 12 Triumph | standing, a hand on his heart | **One-shot:** `a slow, dignified nod with a hand on his heart` |
| 13 Fizzle | (no frame yet) | **One-shot:** `coughs, waving a hand in front of his face, head bowing slightly` |

## Cleric

- **Subject:** `an old cleric in white and gold robes and a tall mitre, holding a short golden mace`
- **Camera:** low top-down, south-east. **Temperament:** a calm, old healer; slow, gentle moves.

| Pose | Initial pose | Prompts |
|---|---|---|
| 01 Idle | short golden mace upright in his right hand, the other hand at rest | **Loop:** `breathing slowly, one blink` · **Fidget:** `raises his free hand to the side of his mitre and straightens it, then lowers the hand` |
| 02 Pondering | head bowed, a hand on the holy symbol at his chest | **Loop:** `bows his head a little deeper, then lifts it slightly` |
| 03 Studying | reading a scroll unrolled between his hands | **Loop:** `his head and eyes move slowly down the scroll` · **Finish:** `rolls the scroll up in both hands` |
| 04 Inscribing | holding a quill above a scroll | **Loop:** `writes small strokes with the quill, hand moving along a line` · **Finish:** `lifts the quill away from the scroll` |
| 05 Channelling | the mace raised, head of the mace above his shoulder | **Loop:** `raises the mace a touch higher and lowers it again` · **Finish:** `lowers the mace to his side, upright` |
| 06 Scrying | gazing at a small floating candle flame in front of his palm | **Loop:** `leans his head a little closer to his palm, then back` · **Finish:** `lifts his head level` |
| 07 Prayer | hands pressed together at his chest, eyes closed | **Loop:** `bows his head slightly deeper, hands still pressed together` · **Finish:** `parts his hands and turns the palms up` |
| 08 Release | both arms held out to the sides, no mace | **One-shot:** `pushes both open hands slightly forward, then holds` |
| 09 Summoning | both arms raised, palms up | **One-shot:** `raises both hands a little higher, palms up` |
| 10 Catching | hands cupped at his waist | **One-shot:** `draws his cupped hands slightly toward his chest` |
| 11 Calling out | the mace raised high | **Loop:** `raises the mace a little higher and back` |
| 12 Triumph | a blessing, two fingers raised | **One-shot:** `a small nod while two raised fingers stay up` |
| 13 Fizzle | (no frame yet) | **One-shot:** `looks at the mace's head, then gives a small apologetic smile and shrug` |

## Paladin

- **Subject:** `a muscular paladin in gold-trimmed steel plate armour and a brown tabard, a closed great helm with a T-shaped eye slit, holding a long-hafted war hammer`
- **Camera:** low top-down, **south** (he faces the viewer). **Temperament:** a stern, stoic protector; few moves,
  slow ones. The hammer is planted head-down whenever the pose allows.

| Pose | Initial pose | Prompts |
|---|---|---|
| 01 Idle | hammer head-down on the ground, both hands on the end of its haft | **Loop:** `breathing slowly, shoulders rising and falling slightly` · **Fidget 1:** `turns his helmed head slowly to one side, watching` · **Fidget 2:** `turns his helmed head slowly to the other side` |
| 02 Pondering | one hand on the hammer's haft, the other on his hip | **Loop:** `a slight slow nod` |
| 03 Studying | reading a tome held in both hands | **Loop:** `turns a page of the tome` · **Finish:** `closes the tome in both hands` |
| 04 Inscribing | hammer resting on his far shoulder, the near hand raised in front, palm up | **Loop:** `lifts his open palm slightly` · **Finish:** `closes his raised hand into a fist` |
| 05 Channelling | one hand on the hammer, the other raised high, helm tilted up | **Loop:** `his raised hand opens and closes slowly` · **Finish:** `lifts the hammer slightly and sets it down` |
| 06 Scrying | idle pose, gaze raised | **Loop:** `tilts his helm up a little and back` · **Finish:** `a slow nod, helm returning level` |
| 07 Salute | the hammer upright in front of him, both hands on the haft, helm bowed behind it | **Loop:** `bows his helm a little deeper and lifts it slightly` · **Finish:** `raises his helm level` |
| 08 Release | hammer on his far shoulder, the near hand opened forward | **One-shot:** `pushes his open near hand forward toward the viewer's right, then holds` |
| 09 Summoning | hammer on his far shoulder, the near fist raised in front | **One-shot:** `raises the fist a little higher` |
| 10 Catching | one hand on the hammer, the near palm up | **One-shot:** `draws his open palm slightly toward his chest` |
| 11 Calling out | pointing straight at the viewer, the other hand on the hammer | **Loop:** `jabs the pointing hand forward once` |
| 12 Triumph | hammer planted, a fist on his chest | **One-shot:** `strikes his fist to his chest, then one slow nod` |
| 13 Fizzle | (no frame yet) | **One-shot:** `looks down at his open palm and shakes his helm once` |

## Druid

No frames yet: his base is being made. Create him first (PixelLab's character tools, or wait for our base), then use
these.

- **Subject:** `a graceful slim elf druid with big antlers and a leaf crown, pointed ears, no beard, fair ageless features, a leaf-cut cloak and clothes in earthy browns and ochre, bare-handed`
- **Camera:** low top-down, south-east. **Temperament:** graceful; livelier than the wizard and the cleric but
  elegant, with flowing, sweeping arm moves, never abrupt.

| Pose | Initial pose | Prompts |
|---|---|---|
| 01 Idle | standing light on his feet, arms relaxed, one hand loosely open | **Loop:** `breathing softly, one blink` · **Fidget 1:** `reaches out gracefully and catches a falling leaf in his open hand` · **Fidget 2:** `tilts his head to one side as if listening to birds, then back` |
| 02 Pondering | hand on his chin | **Loop:** `taps his chin with one finger, eyes drifting upward` |
| 03 Studying | a small songbird perched on his extended hand, the other hand at his chest | **Loop:** `nods gently in time, the bird on his hand singing with its beak opening` · **Finish:** `the bird lifts off his hand with wings raised` |
| 04 Inscribing | drawing in the air with one raised hand | **Loop:** `traces slow curling shapes in the air with his fingertips` · **Finish:** `opens his hand and lets it fall gracefully` |
| 05 Channelling | both hands held in front of him, palms facing | **Loop:** `his hands circle slowly around each other, palms facing` · **Finish:** `sweeps both hands outward and down` |
| 06 Scrying | head tilted, eyes closed, one hand raised to his pointed ear | **Loop:** `holds still, listening, his head tilting slightly further` · **Finish:** `lowers his hand from his ear and opens his eyes` |
| 07 Wild call | an owl perched on his outstretched forearm | **Loop:** `the owl turns its head and ruffles its feathers, his arm stays still` · **Finish:** `the owl spreads its wings and lifts off` |
| 08 Release | right hand swept forward | **One-shot:** `sweeps his right hand forward toward the right in one flowing motion` |
| 09 Summoning | both arms raised, palms up | **One-shot:** `raises both arms gracefully, palms up` |
| 10 Catching | hand open, palm up | **One-shot:** `a butterfly lands on his open palm, he draws the hand in slightly` |
| 11 Calling out | one hand raised high, palm open | **Loop:** `turns his raised open hand gently` |
| 12 Triumph | a bow with a hand on his heart | **One-shot:** `a graceful bow from the waist, a hand on his heart, then rises` |
| 13 Fizzle | (no frame yet) | **One-shot:** `looks at his palm as a wilted leaf falls from it, a small shrug` |

## Barbarian

No frames yet.

- **Subject:** `a muscular barbarian with braided hair and beard, furs and leather, carrying a big axe`
- **Camera:** low top-down, south-east. **Temperament:** not set in the notes yet; big and blunt is the natural
  reading.

| Pose | Initial pose | Prompts |
|---|---|---|
| 01 Idle | axe resting on his shoulder | **Loop:** `breathing heavily, chest rising and falling` · **Fidget 1:** `drops the axe from his shoulder into both hands across his body, then swings it back up` · **Fidget 2:** `scratches his beard` |
| 02 Pondering | scratching his head, frowning | **Loop:** `scratches his head, frowning` |
| 03 Studying | squinting at a crumpled map held at arm's length | **Loop:** `turns the map in his hands, squinting` · **Finish:** `stuffs the map into his belt` |
| 04 Inscribing | carving into a wooden board with the axe's edge | **Loop:** `scrapes short cuts into the board with the axe's edge` · **Finish:** `one last hard cut, then lifts the axe` |
| 05 Channelling | the near fist clenched, the axe in the hand behind him | **Loop:** `clenches his fist tighter, shoulders tensing` · **Finish:** `relaxes his fist and shoulders` |
| 06 Scrying | a hand shading his eyes, peering into the distance | **Loop:** `turns his head slowly from side to side, peering` · **Finish:** `lowers his shading hand` |
| 07 War cry | head thrown back, roaring, the axe raised | **Loop:** `roars, head shaking slightly` · **Finish:** `brings the axe down to rest on his shoulder` |
| 08 Release | throwing an arm forward | **One-shot:** `throws his arm forward toward the right, open hand` |
| 09 Summoning | two fingers at his mouth | **One-shot:** `whistles with two fingers at his mouth` |
| 10 Catching | one fist raised | **One-shot:** `snatches something out of the air with one fist` |
| 11 Calling out | waving the axe overhead | **Loop:** `waves the axe overhead side to side` |
| 12 Triumph | flexing, the axe raised high | **One-shot:** `flexes his arm, lifting the axe high` |
| 13 Fizzle | the axe head stuck in the ground | **One-shot:** `tugs at the stuck axe sheepishly` |

## Rogue

No frames yet.

- **Subject:** `a slim rogue in a dark purple hood and mask and leather armour, holding a dagger in each hand, crouched`
- **Camera:** low top-down, south-east. **Temperament:** always sneaking: a slight crouch in almost every pose, quick
  and quiet moves. The face stays masked.

| Pose | Initial pose | Prompts |
|---|---|---|
| 01 Idle | crouched in a sneak, a dagger in each hand | **Loop:** `breathing quietly in a crouch` · **Fidget 1:** `perks up a little and looks to one side, then sinks back` · **Fidget 2:** `perks up a little and looks to the other side, then sinks back` |
| 02 Pondering | crouched, the near hand at his chin, dagger held loosely | **Loop:** `his eyes dart left and right, head still` |
| 03 Studying | crouched, reading a letter held close | **Loop:** `his eyes move along the letter` · **Finish:** `folds the letter away into his cloak` |
| 04 Inscribing | crouched lower, writing on parchment on his knee | **Loop:** `writes with a quill on the parchment on his knee` · **Finish:** `rolls the parchment and pockets it` |
| 05 Channelling | hands held slightly in front, palms facing each other | **Loop:** `hands circle slowly, palms facing` · **Finish:** `raises one hand sharply` |
| 06 Scrying | crouched, looking through a small spyglass | **Loop:** `sweeps the spyglass slowly side to side` · **Finish:** `snaps the spyglass shut` |
| 07 Misty step | the same sneak stance, as a dark violet shadow form | **Loop:** `breathing slightly in the crouch` · **Finish:** `steps out of the shadow form back to normal` |
| 08 Release | crouched, throwing arm drawn back | **One-shot:** `throws a dagger forward toward the right from the crouch` |
| 09 Summoning | crouched, one hand on the ground, cloak spread | **One-shot:** `presses his hand to the ground, cloak spreading` |
| 10 Catching | crouched, one hand raised | **One-shot:** `catches a dagger by the hilt` |
| 11 Calling out | crouched, one hand cupped at his mouth | **Loop:** `beckons with one hand, quietly` |
| 12 Triumph | rising a little from the crouch | **One-shot:** `rises slightly from the crouch and tips his hood` |
| 13 Fizzle | crouched, a dagger slipping | **One-shot:** `fumbles a dagger and catches it clumsily` |

## Bard (redo)

The shipped bard is the old chibi figure (`bard/`), due to be redone slim; his frames still work for trying the tool.

- **Subject:** `a slim, lively bard in a feathered hat, a maroon and teal doublet and a red cape, playing a lute`
- **Camera:** low top-down, south-east. **Temperament:** a showman, the liveliest of the slim classes. He plays almost
  all the time and moves on his feet (a tapping foot, a shift of weight) while his feet stay on the line.

| Pose | Initial pose | Prompts |
|---|---|---|
| 01 Idle | strumming the lute | **Loop:** `strums the lute, a small head nod, one foot tapping` (no fidgets: the loop is his fidget) |
| 02 Pondering | the idle pose, not playing, gazing up | **Loop:** `moves his strumming hand to his chin and back to the strings` |
| 03 Studying | reading an open book, lute on his back | **Loop:** `turns a page of the book` · **Finish:** `closes the book in his hands` |
| 04 Inscribing | writing in a book with a quill | **Loop:** `writes with the quill` · **Finish:** `a flick of the wrist with the quill` |
| 05 Channelling | playing the lute | **Loop:** `strums the lute steadily` · **Finish:** `damps the strings with his palm` |
| 06 Scrying | the lute by its neck in one hand, a hand mirror in the other, smiling | **Loop:** `turns his head slightly side to side, admiring himself in the mirror` · **Finish:** `puts the mirror back on his belt` |
| 07 Solo | one foot up on a rock, leaning back a little, playing | **Enter:** `a rock rises from the ground and he plants one foot on it` · **Loop:** `strums hard, nodding his head` · **Finish:** `a last dramatic strum, the rock sinks and he steps back` |
| 08 Release | hand thrust forward, the lute by its neck in the other | **One-shot:** `thrusts his open hand forward toward the right` |
| 09 Summoning | arms raised | **One-shot:** `raises both arms` |
| 10 Catching | palm up | **One-shot:** `draws his open palm toward his chest` |
| 11 Calling out | hand raised | **Loop:** `waves his raised hand` |
| 12 Triumph | a bow from the waist, hat held at his chest | **One-shot:** `bows from the waist, sweeping his hat to his chest, then rises` |
| 13 Fizzle | a sheepish shrug | **One-shot:** `a sheepish shrug, waving smoke away` |
