# Dashboard para GitHub Pages

`index.html` y `mobile.html` son versiones livianas generadas por
`pricing-canasta export`. Cargan Plotly desde CDN y son desplegadas por
`.github/workflows/pages.yml`.

Los HTML autocontenidos para uso offline permanecen en `outputs/` y se distribuyen como
activos de GitHub Releases.
