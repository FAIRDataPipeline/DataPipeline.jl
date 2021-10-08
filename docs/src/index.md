# Introduction

!!! note

    See [here](https://fairdatapipeline.github.io/) for the main FAIR Data Pipeline documentation, and information about the SCRC. This website is for the Julia package only.

**DataPipeline.jl**  -  *the SCRC 'Data Pipeline' in Julia*

## What is the SCRC data pipeline?
Per the SCRC docs, the **Scottish COVID-19 Response Consortium [SCRC]** is a research consortia concisting *"of dozens of individuals from over 30 academic and commercial organisations"* formed in response to [RAMP: Rapid Assistance in Modelling the Pandemic](https://epcced.github.io/ramp/), a directive to the scientific community coordinated by the Royal Society.

A key outcome of the project is to develop more epidemiological models of COVID-19 spread in order to develop a more robust and clearer understanding of the impacts of different exit strategies from lockdown - see the [SCRC docs](https://fairdatapipeline.github.io/) for more information.

As a working process developed by the SCRC, the *data pipeline* can be understood by considering the central kernel of its technological implementation: the **[Data Registry](https://data.scrc.uk/) (DR)**. Essentially it consists of a relational database, and a [RESTful API](https://data.scrc.uk/api/) for reading and writing to the database.

The [database schema](https://data.scrc.uk/static/images/schema.svg) (as illustrated below) is detailed, but key entity types of relevance here include:
- **Data Products** - *metadata*, or information about data 'products'. To elaborate: a data product typically includes a link to, e.g. a table of scientific data, but [for the most part] the underlying data is not actually stored in the DR. This may appear at first glance to be a limitation but there is a key benefit to the approach which is discussed briefly in due course.
- **Code Repo Releases** - i.e. 'models', or a given version of some code that implements, e.g. a statistical model.
- **Code runs** - or model runs, such as the output from a single realisation of the model.

Thus, the Code Repo (and Release) relating to a given statistical model, may be associated with a number of Code Runs, which in turn may be associated with a number of Data Products (as 'inputs' and 'outputs'.)

In summary the data pipeline provides both a centralised repository for [meta]data, and a means of tracking the full history of COVID-related modelling outputs, including data and other inputs, such as the random seed used to generate a particular realisation of a given model.

The resulting 'audit trail' can thus provide transparency, and greatly improve the reproducibility, of published scientific research, even where the models and data used to produce them are complex or sophisticated.

Note that as a working process the pipeline is somewhat cyclical in nature: model outputs can be used to provide inputs for other models, and so on. Thus the audit capabilities of the pipeline process are not limited to individual research projects, models or datasets - it naturally extends to a sequence of ongoing projects, possibly produced by different users and teams ('groups' in the DR.)

In other words, it mirrors the way in which scientific research in general is published, whilst providing a robust solution to vitally important current challenges far beyond the fields of public health and epidemiology, such as reproducibility and transparency.

### The Data Registry

As with the pipeline itself, a key design strength of the Data Registry (DR) is its 'agnosticism'. That is, it is agnostic with respect to both programming languages and [the format of] datasets. Thus, it is compatible even with those that have not been invented yet.

Whilst this is a key strength, it does impose certain constraints on the functionality that can be provided directly within the framework of the DR itself. For example, in order to provide features such as file processing (necessary for the automated import of Data Products from the DR) it is necessary to know the file format in advance. This is also true of data processing in general: in order to do any kind of meaningful data processing, we must know both the structure of a given type of dataset, and how to recognise it in practice.

For that reason, features such as these are instead provided by what can be regarded as an 'automation layer', a set of utility-like software packages (such as this one) and tools that comprise an important layer of the pipline's software ecosystem, because they make it possible for model developers to download data, and otherwise meaningfully interact with the SCRC pipeline process using only a few lines of code.

#### Data Registry schema

```@raw html
<img src="https://data.scrc.uk/static/images/schema.svg" alt="Data Registry schema="height: 80px;"/>
```
Hint: click [here](https://data.scrc.uk/static/images/schema.svg) to expand the image.

## What does this package do?

Similar to the [R](https://fairdatapipeline.github.io/docs/API/R/) and the [python](https://fairdatapipeline.github.io/docs/API/python/) FAIR Data Pipeline API implementations, this package provides a language-specific automation layer [for the language-agnostic **RESTful API** that is used to interact with the DR.] It also handles the downloading (and pre-processing) of Data Products based on that [meta]data.

## Getting started

## Package installation

The package is not currently registered and must be added via the package manager Pkg. From the REPL type `]` to enter Pkg mode and run:

```
pkg> add https://github.com/FAIRDataPipeline/DataPipeline.jl
```
