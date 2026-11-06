# Data-Source Entity Relationships

This document shows the planned relationships within each public or synthetic
data source. Participants from different sources are not linked to one another.

## NHANES

NHANES component files are connected through `SEQN`, the unique survey
participant identifier.

```mermaid
erDiagram
    DEMOGRAPHICS {
        number SEQN PK
        number RIDAGEYR
        number RIAGENDR
        number RIDEXPRG
        number INDFMPIR
        number WTMECPRP
        number SDMVSTRA
        number SDMVPSU
    }

    FERRITIN {
        number SEQN PK
        number LBXFER
        number LBDFERSI
    }

    CBC {
        number SEQN PK
        number LBXHGB
        number LBXRBCSI
        number LBXMCVSI
        number LBXRDW
    }

    DEMOGRAPHICS ||--o| FERRITIN : "SEQN"
    DEMOGRAPHICS ||--o| CBC : "SEQN"