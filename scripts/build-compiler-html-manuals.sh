#!/bin/bash

# Variables
DIR="/tmp"
OCAML_VERSION="4.13"

# Remove old entries
echo "Removing old entries ..."
rm -rf $DIR/ocaml
rm -rf $DIR/html-compiler-manuals

# Create new build directory
echo "Create new build directory ..."
mkdir -p $DIR
cd $DIR

# Clone ocaml/ocaml repository
echo "Clone ocaml repository ..."
git clone git@github.com:ocaml/ocaml.git

echo "Clone html-compiler-manuals ..."
git clone git@github.com:ocaml-web/html-compiler-manuals

# Switch to ocaml branch
echo "Checkout $OCAML_VERSION branch in ocaml ..."
cd ocaml
git checkout $OCAML_VERSION

# Remove any stale files
echo "Running make clean"
make clean
git clean -f -x

# Configure and build
echo "Running configure and make ..."
./configure
make

# Build web
echo "Generating manuals ..."
cd manual
make web

# Move to html-compiler-manuals directory
echo "Creating $OCAML_VERSION branch in html-compiler-manuals ..."
cd $DIR/html-compiler-manuals
git checkout -b $OCAML_VERSION

# Copy webman manuals
echo "Copying webman manuals to html-compiler-manuals ..."
cp -r $DIR/ocaml/manual/src/webman/$OCAML_VERSION .
