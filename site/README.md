# Dashboard para GitHub Pages

`index.html` y `mobile.html` son versiones autocontenidas generadas por
`pricing-canasta export`. Incluyen Plotly directamente en cada documento
(`include_plotlyjs=True`), no lo descargan desde un CDN, y son desplegadas por
`.github/workflows/pages.yml`.

Las copias para uso offline permanecen en `outputs/` y se distribuyen como activos de
GitHub Releases.
