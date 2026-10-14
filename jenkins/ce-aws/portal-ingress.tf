# Local add-on injected by cdp-onprem-automation.
# Reuses the upstream managed prefix list, which contains only JENKINS_IP/32.
resource "aws_vpc_security_group_ingress_rule" "cdp_onprem_portal" {
  security_group_id = aws_security_group.reverse_proxy.id
  description       = "cdp-onprem-automation portal"
  prefix_list_id    = aws_ec2_managed_prefix_list.pvc_base.id
  from_port         = 81
  ip_protocol       = "tcp"
  to_port           = 81
  tags              = { Name = "${var.prefix}-cdp-onprem-portal" }
}
