# Class palettes

Each class's sprites use one fixed palette: at most three shades per material and two outline colours.

- `<class>.gpl`: GIMP palette, loadable in Aseprite, GIMP, Krita and LibreSprite. Swatches are named by group and shade
  (`skin 1` is the darkest).
- `<class>.json`: the same palette as the sprite pipeline stores it (version 2), with the glow colours the effects use.

When fixing frames in `app/Sources/App/Resources/Sprites/<class>/` by hand, paint only with that class's swatches.
