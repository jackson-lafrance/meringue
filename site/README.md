# meringue.sh

The site is a dependency-free static page: semantic HTML and one CSS file.

## Preview locally

From the repository root:

```bash
ruby -run -e httpd site -p 8000
```

Open <http://localhost:8000> and stop the server with `Ctrl-C`.

The page is host-agnostic and can be deployed to any static host. Configure the
host or custom domain separately from this repository.
