# Java

**Debian section:** `java`. **Status:** libraries install; the JRE/JDK does
not install through apt, use `tools/deb2home.sh`.

| problem | fix |
|---|---|
| `java-common` and `openjdk-*-jre-headless` postinst run `mkdir -m 755 /etc/.java`, unguarded: root only, `dpkg --configure` fails | extract the JDK without its maintainer scripts: `tools/deb2home.sh openjdk-25-jre-headless`, then set `JAVA_HOME` (the JVM creates its preferences dir lazily, so `/etc/.java` is not needed) |
| a library jar is found only on the classpath | `CLASSPATH` or the application's own launcher (mechanism `env`) |

There is no shim: the failing call is a bare `mkdir` against `/etc`, and
shimming `mkdir` would catch every other script.

Examples: `recipes/openjdk-25-jre-headless.recipe` (the JDK version is
pinned; update it when Debian's default JDK moves),
`recipes/prismlauncher.recipe` (a Java GUI app). History: issue #7.

**To do:** a helper that finds Debian's current default JDK and sets
`JAVA_HOME`, instead of a pinned recipe.
