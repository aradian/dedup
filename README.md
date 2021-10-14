# dedup.pl

This is a portable script for managing large and unorganized collections of files. It has features to help deduplicate files with identical content.

## OPTIONS

- `--base /path/to/dir`

    Path to the directory which will be operated on.

- `--dedup`

    Find duplicate files under the base directory and prompt the user to decide how to handle each set of duplicates.
    Also, creates a hidden cache directory under the base directory to store checksums and speed up future runs.

- `--no-dedup-cache`

    Do not create a the dedup checksum cache directory.

- `--rank`

    Rank files under the base directory by date modified and size. Present the highest ranking files to the user. By default, older and larger correspond to higher rank.

- `--rank-weight-age X`

    Adjust the weight given to a file's last modified date when calculating a file's rank.
    Default 1.0.

- `--rank-weight-size X`

    Adjust the weight given to file size when calculating a file's rank.
    Default 1.0.

- `--help`

    Display this help message.

## --dedup FEATURES

For each set of duplicate files found, the user can choose actions to take. The files are presented in a numbered list, followed by a prompt. The response should be of the form: `action N N ...`, where `action` is a letter or word indicating the action and optionally followed by numbers corresponding to files in the list, if needed.

Possible actions are:

- `d` or `rm`

    Delete the indicated files. Defaults to no action if no list of files is provided.

- `l` or `link`

    Make indicated files in the list hard links to each other. Defaults to all files if no list of files is provided.

- `m` or `mv`

    Requires exactly two files. Delete the second file and move the first file to the directory that the second file was in.

- `c`

    Clear the cache of the indicated files. Defaults to all files if no list of files is provided.

## --rank FEATURES

Ranks all files under the base directory and presents the top 25. By default, both larger file size and earlier modified date contribute to higher ranking. Use the `--rank-weight-*` options to adjust. Weights are in proportion to each other, so e.g. age=1.0 and size=2.0 would result in age having 33% weight and size having 67% weight.

Rank mode may be expanded in the future.
