# Introduction

!!! note

    Please note that this package is still in development.

**DataRegistryUtils.jl**  -  *the SCRC 'Data Pipeline' in Julia*

## What is the SCRC data pipeline?
Per the SCRC docs, the **Scottish COVID-19 Response Consortium [SCRC]** is a research consortia *"formed of dozens of individuals from over 30 academic and commercial organisations"* focussed on COVID-related research.

A key outcome of the project is to develop more epidemiological models of COVID-19 spread in order to develop a more robust and clearer understanding of the impacts of different exit strategies from lockdown - see the SCRC docs for more information.

The data pipeline can be understood by considering its central kernel: the SCRC **[Data Registry](https://data.scrc.uk/)** (DR). Essentially it consists of a relational database, and a [RESTful API](https://data.scrc.uk/api/) for reading and writing to the database.

The [database schema](https://data.scrc.uk/static/images/schema.svg) (as illustrated below) is detailed, but the key entity types of relevance to the data pipeline are:
- **Data Products** - *metadata*, or information about data products (not the data itself.)
- **Code Repo Releases** - i.e. 'models', or model code.
- **Code runs** (or model runs)

Thus, the Code Repo (and Release) of a particular model may be associated with a number of Code Runs; which in turn may be associated with a number of Data Products ('inputs' and 'outputs'.)

In summary the data pipeline provides both a centralised repository for [meta]data, and a means of tracking the full history of COVID-related modelling outputs, including data and other inputs, such as the random seed used to generate a particular realisation of a given model.

### The SCRC Data Registry

#### Database schema

```@raw html
<img src="https://data.scrc.uk/static/images/schema.svg" alt="SCRC Data Registry schema="height: 80px;"/>
```
Hint: click [here](https://data.scrc.uk/static/images/schema.svg) to expand the image.

## What does this package do?

Similar to the [SCRCData package for R](https://scottishcovidresponse.github.io/docs/data_pipeline/R/) and the [data_pipeline_api package](https://scottishcovidresponse.github.io/docs/data_pipeline/python/) for Python, this package provides a language-specific automation layer for the language-agnostic **RESTful API** that is used to interact with the DR. It also handles the downloading (and pre-processing) of Data Products based on that [meta]data.

Key features include:
- Downloads Data Products specified by a given .yaml config file.
- File hash-based version checking: new data is downloaded only when necessary.
- A SQLite layer for convenient pre-processing (typically aggregation, and the joining of disparate datasets based on common identifiers.)

### SQLite layer

The SQLite layer is optional - the data can also be returned as a set of nested Dictionaries. However it is the recommended way of using the package since it provides for convenient pre-processing and as well as certain planned features of the package.

## Further development work

There is ongoing development work to do, subject to feedback from users. In particular:

### Registering data products

The registration of Data Products, including but not limited to model outputs, in the DR is a WIP.

### SQL-based access logs (a component of Code Run objects)

Existing functionality for recording data usage in model runs is based on the individual data products specified in the data configuration .yaml file. However since data products may include multiple components, it would be better to have a more precise record of the data that is actually utilised. This functionality is currently being implemented via the aforementioned SQLite layer.

Features in consideration include optional 'tags' specified by the user at the point of [data] access - passed as a parameter to a given function call. It is anticipated that these tags could be used to record information such as the calling Julia Module / line of code; key filters and aggregation levels used to process the data; or even references to downstream outputs, e.g. *'Page x, Table y in Report z.'*

### Suggestions welcome!

Feel free to reach out: **martin.burke@bioss.ac.uk**
