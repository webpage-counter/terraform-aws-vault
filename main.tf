# Below are resources needed for enabling the consul auto-join function. 
# EC2 instaces need to have iam_instance_profile with the below policy and 
# set of rules so each EC2 can read the metadata in order to find the private_ips based on a specific tag key/value.
data "terraform_remote_state" "nw" {
  backend = "remote"

  config = {
    organization = "webpage-counter"
    workspaces = {
      name = "ops-aws-network"
    }
    token = var.token
  }
}

data "terraform_remote_state" "consul" {
  backend = "remote"

  config = {
    organization = "webpage-counter"
    workspaces = {
      name = "ops-aws-consul"
    }
    token = var.token
  }
}



# Data source that is needed in order to dinamicly publish values of variables into the script that is creating Consul configuration files and starting it.

data "template_file" "var" {
  template = file("${path.module}/scripts/start_consul.tpl")

  vars = {
    DOMAIN       = var.domain
    DCNAME       = var.dcname
    LOG_LEVEL    = "debug"
    SERVER_COUNT = var.server_count
    var2         = "$(hostname)"
    IP           = "$(hostname -I | cut -d \" \" -f1)"
    JOIN_WAN     = var.join_wan
    pass         = var.pass
  }
}

# Below are the 3 Consul servers and 1 consul client.
resource "aws_instance" "vault_server" {
  ami                         = var.ami
  instance_type               = var.instance_type
  subnet_id                   = data.terraform_remote_state.nw.outputs.private_subnets[1]
  vpc_security_group_ids      = ["${data.terraform_remote_state.nw.outputs.pubic_sec_group}"]
  iam_instance_profile        = data.terraform_remote_state.consul.outputs.instance_profile
  private_ip                  = "${var.IP["vault"]}${count.index + 1}"
  key_name                    = "denislav_key_pair"
  associate_public_ip_address = false  
  count                       = var.server_count
  user_data                   = data.template_file.var.rendered
  depends_on                  = [data.terraform_remote_state.nw]

  tags = {
    Name     = "vault-server${count.index + 1}"
    consul   = var.dcname
    join_wan = var.join_wan
  }

}

# Outputs the instances public ips.


output "ami" {
  value = var.ami
}

output "dcname" {
  value = var.dcname
}

output "IP_client" {
  value = var.IP["client"]
}

output "data_rendered" {
  value      = data.template_file.var.rendered
  depends_on = [data.template_file.var]
}

