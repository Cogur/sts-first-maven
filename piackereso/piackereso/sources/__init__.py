from . import facebook, hardverapro, jofogas, vinted

# Order here is the order of the source chips in the UI.
SOURCES = {m.KEY: m for m in (hardverapro, jofogas, vinted, facebook)}
