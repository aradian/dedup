#!/bin/sh

perl -MPod::Markdown -e 'Pod::Markdown->new->filter("dedup.pl");' > README.md

