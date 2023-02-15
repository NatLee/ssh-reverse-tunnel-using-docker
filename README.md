# SSH Reverse Tunnel using docker with Outside SSH Server

This script will help you to dig a hole in the inside network using container with docker and create a tunneling server.

> BTW, you will need a outside SSH server to handle this tunnel.

## Usage

0. Check the `.env.example` file and save another one to `.env`.

1. Generate pairs of key

```bash
bash ./keygen.sh
```

> Tunnel private user key in `./src/user_ssh_key/id_rsa` -> use to connect inside local servers.

> Tunnel private server key in `./src/root_ssh_key/id_rsa` -> use to connect your outside tunnel server.

2. Test connecting to the outside server specified in `.env` file

```bash
bash ./connect.sh
```

3. Run this command and copy the public key into outside server file `~/.ssh/authorized_keys`

```bash
echo $(cat ./src/root_ssh_key/id_rsa.pub)
```

Or you can copy key with this command:

```bash
ssh-copy-id <YOUR_USERNAME_IN_OUTSIDE_SERVER>@<YOUR_OUSIDE_SERVER> -i ./src/root_ssh_key/id_rsa
```


4. Start the OpenSSH server for tunneling inside

```bash
bash ./run.sh
```

### Notice

In the first time, you need to go through the all steps.

When you turn on this tunnel in the second time, just feeling free to run step 4.

## Enter Container

```
docker exec -it reverse-inside-tunnel /bin/bash
```

## Misc

- Copy public key to server

  ```bash
  ssh-copy-id <YOUR_SERVER_ADDRESS>
  ```

- SSH Config Example

  ```
  Host SELF
      HostName localhost
      User natlee
      Compression yes
  ```
