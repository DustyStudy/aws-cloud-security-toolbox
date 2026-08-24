import boto3


def handler(events, context):
    ec2 = boto3.client("ec2")
    instance_id = events["InstanceId"]
    incident_id = events.get("IncidentId") or "unspecified"
    resp = ec2.describe_instances(InstanceIds=[instance_id])
    snapshot_ids = []
    for reservation in resp["Reservations"]:
        for instance in reservation["Instances"]:
            for bdm in instance.get("BlockDeviceMappings", []):
                ebs = bdm.get("Ebs")
                if not ebs:
                    continue
                volume_id = ebs["VolumeId"]
                snap = ec2.create_snapshot(
                    VolumeId=volume_id,
                    Description=(
                        f"IR isolation snapshot of {volume_id} "
                        f"from instance {instance_id} (incident {incident_id})"
                    ),
                    TagSpecifications=[{
                        "ResourceType": "snapshot",
                        "Tags": [
                            {"Key": "IsolationIncidentId", "Value": incident_id},
                            {"Key": "SourceInstanceId", "Value": instance_id},
                        ],
                    }],
                )
                snapshot_ids.append(snap["SnapshotId"])
    return {"SnapshotIds": snapshot_ids}
