# Image and artwork sources

## Lunar surface

`MoonAlbedo.jpg`: NASA Scientific Visualization Studio, **CGI Moon Kit**, 2025 LROC color map, 2048 × 1024.

Source: https://svs.gsfc.nasa.gov/4720/
Image: https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/lroc_color_2k.jpg

Credit: NASA's Scientific Visualization Studio. The photographic mosaic is derived from Lunar Reconnaissance Orbiter Camera data (NASA / GSFC / Arizona State University). The map is adapted for visualisation, not scientific surface measurements.

Use subject to NASA's media guidelines: https://www.nasa.gov/nasa-brand-center/images-and-media/
No NASA logo is used. NASA does not endorse this application. The rendering, illumination and calculated sky positions are this app's work, not a NASA-produced image of current conditions.

## Cloud atlas

`CloudAtlas.png`: sixteen original formations in one 1536 × 1536 atlas: feathered cirrus, stratocumulus, cumulus, and rain/anvil banks. Generated offline with `Scripts/GenerateClouds.swift` and `Scripts/CloudBaker.metal`. Wisps use offline anisotropic artwork; lower formations use offline volumetric rendering. The previous/comparison renderer draws these as 24 layered instances, without runtime ray marching. No Apple imagery or extracted system assets are included.

## Hybrid atmosphere

`Atmosphere.metal`: original analytical sky, periodic 3D shape/erosion generator, cloud integration, distant ice-cloud fields and linear-light composition. Noise resources are generated once on the GPU and shared by every renderer. No iOS Weather screenshots, extracted assets, private shaders or third-party render libraries are embedded. The retained cloud atlas described above is used only by the previous renderer/comparison path.

Cloud-family morphology references: WMO International Cloud Atlas, ten genera and their definitions, https://cloudatlas.wmo.int/en/clouds-genera.html. Definitions guide original density profiles; WMO photographs are not included. Low/mid/high fractions come from Open-Meteo model data and do not identify observed cloud genera. Named family previews are explicitly illustrative.

## Weather data

Current model-derived conditions and forecasts: Open-Meteo, https://open-meteo.com/.
Data licence: Creative Commons Attribution 4.0 International, https://creativecommons.org/licenses/by/4.0/.
Provider and underlying sources: https://open-meteo.com/en/licence.

The app adapts weather data into an artistic sky illustration and normalizes precipitation accumulation to an hourly rate. These visualizations are not on-site measurements or safety warnings. Open-Meteo does not endorse this app. The public API is for eligible non-commercial use; commercial distribution requires an appropriate provider plan. No Open-Meteo server source code is embedded in this app.
