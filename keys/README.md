# Claves públicas SSH de los usuarios

Para que un usuario pueda entrar por SSH con clave, guardar acá su **clave pública** con el nombre
`<usuario>.pub` (por ejemplo `keys/kakashi.pub`). `setup.sh` la instala en
`/home/<usuario>/.ssh/authorized_keys`.

Generar el par de claves en la computadora del cliente (la clave **privada** nunca sale de ahí):

```bash
ssh-keygen -t ed25519 -C "kakashi@tp2"
cat ~/.ssh/id_ed25519.pub      # <- esto es lo que va en keys/kakashi.pub
```

Las claves públicas se pueden subir al repositorio sin problema.
Las privadas (`id_ed25519`, sin `.pub`) **jamás**.
