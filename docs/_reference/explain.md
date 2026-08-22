---
title: Explain
nav_order: 5
description: Ask one file, constant, or component what reaches it, what it reaches, which rules and findings touch it, and what would change if it left its components.
seo:
  title: ArchSpec explain, the reverse questions
---

# Explain

`archspec check` answers whether the tree matches the architecture. `archspec explain` answers the questions a person asks next, about one subject at a time: what reaches this, what does it reach, which rules admit it, why is this finding here, and what breaks if it moves.

```sh
bundle exec archspec explain app/models/user.rb
bundle exec archspec explain Billing::Invoice
bundle exec archspec explain models
```

## Where the answer comes from

The first printed line names the origin. When `.archspec/` holds a snapshot this version of ArchSpec took of this tree, `explain` reads the graph from it and prints the snapshot's commit. When it does not, `explain` analyses the working tree and says why the snapshot could not be used: no snapshot has been taken, the files it read have changed on disk, the tree is at another commit, the working tree has changes, or the source and ignore patterns differ. Reading from a snapshot and analysing afresh never print the same first line, so a stale answer cannot pass as a current one.

Either way `explain` then runs the rules over that graph with the todo file, exactly as `check` does, so every finding it prints carries the reason, the suggested action, the date verdict and the confidence the check printed.

## A file

The file's own facts come first: the constants it defines, the components it belongs to with the pattern or selector that admitted it, the patterns that excluded it, its parse errors and its suppressions.

Then the reverse questions. Incoming facts list every dependency edge whose resolved target is a constant this file defines, grouped by kind, each with its source constant, its location and the components the source belongs to. Outgoing facts list the file's own edges, each marked `lexical` or `unresolved` by how the parser resolved it, or `facts` with the producer's name when a facts file supplied it. The census rows name what the run could not see in this file: references that resolved to no definition, dynamic features by line, and calls on receivers of unknown kind.

The rules section lists every rule that names one of the file's components, with its reason. Findings lists each diagnostic located in the file. The last section answers what would change if the file left every component: the rules are run once more over a graph where this file belongs to nothing, and the findings that appear are what would start failing, the findings that vanish are what would stop being checked. A rule that raises during that second run, or a custom rule that carries no id, is listed as not computed.

## A constant

Everything a file gets, scoped to the constant, plus its ancestry as the graph resolved it. Each superclass, include, prepend and extend link names what it resolved to and how: `lexical` when the parser found the definition, `unresolved` when the graph holds no definition for it, and the producer's name when a facts file supplied the link. An unresolved ancestor ends its branch rather than being skipped.

## A component

Its files and constants, its public face as declared by `public_api`, fan-in and fan-out as edge counts by neighbouring component, and the rules and findings that touch it.

## JSON

```sh
bundle exec archspec explain app/models/user.rb --format json
```

One object with the same sections: `origin`, `subject`, and for a file `defined_constants`, `parse_errors`, `components`, `excluded_from`, `suppressions`, `incoming`, `outgoing`, `census`, `rules`, `diagnostics` and `blast_radius` with `appearing`, `vanishing` and `not_computed`. A constant adds `constants` with each definition's `ancestry`; a component carries `members`, `public_face`, `fan_in`, `fan_out`, `rules` and `diagnostics`.

## What explain does not do

It never boots the application, never writes, and asks one subject at a time. It does not walk transitive reach: incoming facts are one hop. The blast radius is computed for the one move the graph can express without guessing, the file leaving its components; a move into another component would need that component's rules and is not simulated.
