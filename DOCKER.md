## Add Docker image to run the Haskell environment

```bash
$ docker pull haskell
$ git clone git@github.com:peter-maday/matrizer.git
$ docker run -it --rm -v $PWD/matrizer:/code haskell bash
```
