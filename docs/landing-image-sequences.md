# Landing feature image sequences

## Current nine-frame sequences

The sequences scrub from 20% to 60% of their feature stage's view timeline (`cover` range), with eight evenly spaced dissolves. They hold the first frame before 20% and the final frame after 60%, and reverse when scrolling back. Reduced motion keeps the final illustration visible.

The landing page now uses nine generated frames per illustration in `server/public/images/marketing/sequences/v2/`. The 27 WebP files are 510×340 pixels, encoded at quality 88, and total 551,968 bytes. The built-in imagegen tool generated three 3×3 sheets using the original sheets as references. Each new sheet is used as one continuous sequence to avoid jumping between differently framed generations. The original assets remain available below.

Eight crossfades share the existing 40–100% entry range (7.5% each), preserving the latest timing and the final-frame hold. Reduced motion still shows only the last frame. These are generated keyframe dissolves, not optical-flow video interpolation.

### Book refinement prompt

Using the attached 2x2 book animation sheet as the EXACT visual reference, generate NINE NEW in-between animation frames as a 3-column x 3-row sprite sheet. Overall landscape 3:2, each cell 3:2, maximum resolution. No gutters, borders, text or numbering. Preserve camera, book size, desk, plant, pencil, palette and tactile paper/clay textures precisely. Reference frames are A top-left closed, B top-right cover partly raised, C bottom-left pages fanning, D bottom-right fully open. Output row1: three evenly spaced intermediate poses strictly BETWEEN A and B (25%,50%,75%); row2: three intermediate poses BETWEEN B and C; row3: three intermediate poses BETWEEN C and D, with cover and pages rotating progressively leftward until almost flat open. These are actual progressive poses, not crossfaded images. Background and objects must stay perfectly stationary with no zoom. Each frame uses the same full scene framing as one reference cell. No extra props. The output will be sliced and interleaved with originals to create a smooth 13-frame animation.

### Chip refinement prompt

Use this reference sheet's tactile paper/clay cards scene to create a smoother NINE-frame animation sprite sheet: exactly 3 columns by 3 rows, overall landscape 3:2, equal 3:2 panels, no gutters, labels, borders or text. SAME locked camera, identical background props and object scale across ALL nine frames. Preserve cream navy coral lavender art direction. Row-major chronological progression: frame1 blank stacked cards; frame2 slight fan; frame3 wider fan and small sun emerging; frame4 fan continues and sun grows; frame5 faint lavender mountain shapes rise; frame6 layered mountains and navy river details develop; frame7 landscapes complete and first short summary bars appear; frame8 more summary bars; frame9 completed three illustrated cards with full abstract navy summary bars and coral tags as in reference final panel. Small progressive changes between adjacent frames. Keep cards centered at consistent scale, no camera motion. Maximum resolution. Generate a complete nine-frame sequence, not nine unrelated illustrations.

### Trip refinement prompt

Use this reference sheet's tactile paper/clay travel map scene to create a smoother NINE-frame animation sprite sheet: exactly 3 columns by 3 rows, overall landscape 3:2, equal 3:2 panels, no gutters, labels, borders or text. SAME locked camera, identical background props, mountains, trees, river, suitcase and map scale across ALL nine frames. Preserve cream navy coral lavender art direction. Row-major chronological progression: frame1 empty route with no coral pins; frame2 first coral pin begins rising; frame3 first pin full height and short coral dashed route starts; frame4 route extends toward center; frame5 second pin begins rising at center; frame6 second pin full height and route crosses river; frame7 route continues toward right; frame8 third pin rises at right; frame9 complete three-pin route as in reference final panel. Small progressive changes between adjacent frames. Keep map centered at consistent scale, no camera motion. Maximum resolution. Generate a complete nine-frame sequence, not nine unrelated illustrations.

## Original four-frame sequences

Generated using the built-in imagegen tool. Each source is a 2×2 sheet, sliced into four 768×512 WebP frames with Sharp (quality 85). The 12 frames total approximately 377 KiB and live in `server/public/images/marketing/sequences/`.

The papers, chips and trips SVG illustrations are replaced with generated raster keyframes. CSS scroll timelines crossfade between the frames in both directions. This is a four-keyframe dissolve sequence, not an interpolated video. Reduced-motion preferences and browsers without scroll-timeline support show the final illustration. The podcast illustration is unchanged.

## Generation prompts

### Papers

Create a production animation sprite sheet, landscape 3:2 overall aspect ratio, exactly 2 columns x 2 rows of equal panels, zero gutters, zero borders, no labels or text. Each panel is a 3:2 frame of the SAME locked camera and SAME scene. Premium tactile clay and paper miniature illustration for Chippy website: cream background, navy book, coral bookmark, lavender accents, soft studio shadows, richly textured 3D editorial art, not flat vector. A research book rests centered on a desk with a small pencil at bottom left. Four chronological animation keyframes reading left-to-right top-to-bottom: 1 closed navy book; 2 cover lifts 45 degrees; 3 book nearly open with pages fanning; 4 fully open book displaying abstract research charts. Maintain identical position scale lighting and objects in each panel, generous safe margins. No lettering, no extra panels. This sheet will be sliced into four frames for scroll animation.

### Chips

Create a production animation sprite sheet, landscape 3:2 overall aspect ratio, exactly 2 columns x 2 rows of equal panels, zero gutters, zero borders, no labels or text. Each panel is a 3:2 frame of the SAME locked camera and SAME scene. Premium tactile clay and paper miniature illustration for Chippy website: cream studio background, navy coral lavender palette, soft studio shadows, richly textured 3D editorial art, not flat vector. Three thick rounded cream summary cards centered on a cream tabletop. Four chronological animation keyframes reading left-to-right top-to-bottom: 1 three blank cards stacked neatly; 2 cards begin fanning out and the front card gains a small coral sun; 3 cards nearly fully fanned with lavender miniature mountain landscapes appearing on each; 4 three beautiful fully illustrated summary cards fanned out with navy abstract embossed summary lines below their landscapes and coral pill tags. Maintain identical camera position scale lighting and objects in each panel, generous safe margins. No lettering, no extra panels. This sheet will be sliced into four frames for scroll animation.

### Trips

Create a production animation sprite sheet, landscape 3:2 overall aspect ratio, exactly 2 columns x 2 rows of equal panels, zero gutters, zero borders, no labels or text. Each panel is a 3:2 frame of the SAME locked camera and SAME scene. Premium tactile clay and paper miniature illustration for Chippy website: cream studio background, navy coral lavender palette, soft studio shadows, richly textured 3D editorial art, not flat vector. An unfolded cream travel map centered on a tabletop, tiny lavender mountains navy trees and pale blue river, small coral suitcase at bottom right. Four chronological animation keyframes reading left-to-right top-to-bottom: 1 map with no pins or route; 2 one coral location pin appears at left and a coral route starts; 3 route curls through center and second coral location pin appears; 4 completed coral route connects three coral location pins left center right across the miniature map. Maintain identical camera position scale lighting and objects in each panel, generous safe margins. No lettering, no extra panels. This sheet will be sliced into four frames for scroll animation.
