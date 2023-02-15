#/bin/bash
export $(cat ./.env)

echo "---- Display public key used in AutoSSH"
echo $(cat ./src/root_ssh_key/id_rsa.pub)
echo ""

echo "-------- Display .env"
echo "Reverse server Host is $REVERSE_SERVER_HOST"
echo "Reverse server user is $REVERSE_SERVER_USER_NAME"
echo "Reverse server SSH port is $REVERSE_SERVER_SSH_PORT"
echo "Command -> $REVERSE_SERVER_USER_NAME@$REVERSE_SERVER_HOST -p $REVERSE_SERVER_SSH_PORT"
echo ""

echo "---- Starting link outside tunnel server with SSH"
ssh $REVERSE_SERVER_USER_NAME@$REVERSE_SERVER_HOST -p $REVERSE_SERVER_SSH_PORT -i ./src/root_ssh_key/id_rsa
