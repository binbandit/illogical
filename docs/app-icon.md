# App icon

The illogical icon uses a flowing white mark with a detached dot, over a soft
lavender, coral, apricot, yellow, and mint gradient. It takes its visual direction
from [Superlogical's icon](https://www.superlogical.com/apple-touch-icon.png): a
simple white curve and a warm luminous background. The mark has its own vector
geometry rather than reproducing the reference's continuous S.

The editable master is `scripts/render-app-icon.swift`. From the repository root:

```sh
swift scripts/render-app-icon.swift
```

This writes the ten macOS asset variants (16 through 1024 pixels) to
`illogical/Assets.xcassets/AppIcon.appiconset`. Smaller variants omit the tile's fine
edge highlight. Rendering uses Core Graphics in sRGB, supersampling, and transparent
padding around the tile. The script only runs when changing the icon, never at
application launch.

Both Debug and Release use the `AppIcon` asset catalog. Xcode packages the icon
and supplies the application bundle's icon metadata during the build.
