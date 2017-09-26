provider “aws” {
	region = “eu-west-1”
	shared_credentials_file = “/home/suresh/.aws/credentials” 
}

resource “aws_launch_configuration” “webtier” {
	image_id= “ami-xxxxxxxxx”
	instance_type = “t2.micro”
	security_groups = [“${aws_security_group.webserver-sg.id}”]
	key_name = “suresh_keypair”
	user_data = <<-EOF
		#!/bin/bash
		yum install gcc -y
		yum install python-devel libffi-devel openssl-devel -y
		pip install paramiko PyYAML Jinja2 httplib2 six markupsafe docker-py ansible boto -q
		pip install --upgrade setuptools -q
		easy_install ansible
		pip install pywinrm -q
		cd /
		git clone git clone https://github.com/sureshkanniappan/TF-ELB-ASG.git
		cd TF-ELB-ASG-master
		ansible-playbook deploy-apache.yaml
	EOF

	lifecycle {
		create_before_destroy = true
	}
}

data “aws_availability_zones” “allzones” {}

resource “aws_autoscaling_group” “autoscalegroup” {
	launch_configuration = “${aws_launch_configuration.webtier.name}”
	availability_zones = [“${data.aws_availability_zones.allzones.names}”]
	min_size = 9
	max_size = 12
	enabled_metrics = [“GroupMinSize”, “GroupMaxSize”, “GroupDesiredCapacity”, “GroupInServiceInstances”, “GroupTotalInstances”]
		metrics_granularity=”1Minute”
	load_balancers= [“${aws_elb.webelb.id}”]
	health_check_type=”ELB”
	tag {
		key = “Name”
		value = “AutoScaleGroup”
		propagate_at_launch = true
	}
}

resource “aws_autoscaling_policy” “scaleup-policy” {
	name = “autopolicy-up”
	scaling_adjustment = 1
	adjustment_type = “ChangeInCapacity”
	cooldown = 300
	autoscaling_group_name = “${aws_autoscaling_group.autoscalegroup.name}”
}

resource “aws_cloudwatch_metric_alarm” “cpualarm-scaleup” {
	alarm_name = “cpu-alarm-up”
	comparison_operator = “GreaterThanOrEqualToThreshold”
	evaluation_periods = “2”
	metric_name = “CPUUtilization”
	namespace = “AWS/EC2”
	period = “120”
	statistic = “Average”
	threshold = “80”

	dimensions {
		AutoScalingGroupName = “${aws_autoscaling_group.autoscalegroup.name}”
	}

	alarm_description = “Metric to monitor the EC2 instance cpu utilization for ScaleUp”
	alarm_actions = [“${aws_autoscaling_policy.scaleup-policy.arn}”]
}

#
resource “aws_autoscaling_policy” “scaledown-policy” {
	name = “autopolicy-down”
	scaling_adjustment = -1
	adjustment_type = “ChangeInCapacity”
	cooldown = 300
	autoscaling_group_name = “${aws_autoscaling_group.autoscalegroup.name}”
}

resource “aws_cloudwatch_metric_alarm” “cpualarm-scaledown” {
	alarm_name = “cpu-alarm-down”
	comparison_operator = “LessThanOrEqualToThreshold”
	evaluation_periods = “2”
	metric_name = “CPUUtilization”
	namespace = “AWS/EC2”
	period = “120”
	statistic = “Average”
	threshold = “10”

	dimensions {
		AutoScalingGroupName = “${aws_autoscaling_group.autoscalegroup.name}”
	}

	alarm_description = “Metric to monitor the EC2 instance cpu utilization for ScaleDown”
	alarm_actions = [“${aws_autoscaling_policy.scaledown-policy.arn}”]
}

resource “aws_security_group” “webserver-sg” {
	name = “security_group_for_web_server”
	ingress {
		from_port = 80
		to_port = 80
		protocol = “tcp”
		cidr_blocks = [“0.0.0.0/0”]
	}
}

resource “aws_security_group_rule” “ssh” {
	security_group_id = “${aws_security_group.webserver-sg.id}”
	type = “ingress”
	from_port = 22
	to_port = 22
	protocol = “tcp”
	cidr_blocks = [“124.108.xxx.xxx/32”]
}

resource “aws_security_group” “webelbsg” {
	name = “security_group_for_elb”
	ingress {
		from_port = 80
		to_port = 80
		protocol = “tcp”
		cidr_blocks = [“0.0.0.0/0”]
	}

	egress {
		from_port = 0
		to_port = 0
		protocol = “-1”
		cidr_blocks = [“0.0.0.0/0”]
	}
}

resource “aws_elb” “webelb” {
	name = “web-elb”
	availability_zones = [“${data.aws_availability_zones.allzones.names}”]
	security_groups = [“${aws_security_group.webelbsg.id}”]
	listener {
		instance_port = 80
		instance_protocol = “http”
		lb_port = 80
		lb_protocol = “http”
	}
	health_check {
		healthy_threshold = 2
		unhealthy_threshold = 2
		timeout = 3
		target = “HTTP:80/”
		interval = 30
	}
	cross_zone_load_balancing = true
	idle_timeout = 400
	connection_draining = true
	connection_draining_timeout = 400

	tags {
		Name = “web-elb”
	}
}

resource “aws_lb_cookie_stickiness_policy” “cookie_stickness” {
	name = “cookiestickness”
	load_balancer = “${aws_elb.webelb.id}”
	lb_port = 80
	cookie_expiration_period = 600
}

output “availabilityzones” {
	value = [“${data.aws_availability_zones.allzones.names}”]
}

output “elb-dns” {
	value = “${aws_elb.webelb.dns_name}”
}