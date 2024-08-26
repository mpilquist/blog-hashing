#!/bin/bash
cs launch org.scalameta:mdoc_3:2.5.2 -- --in README.template.md --out README.md --classpath $(cs fetch -r sonatype-s01:snapshots -r sonatype-s01:releases --classpath co.fs2:fs2-io_3:3.11.0) $*
