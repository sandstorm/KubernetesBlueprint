FROM quay.io/operator-framework/ansible-operator:v1.42.2

COPY requirements.yml ${HOME}/requirements.yml
RUN ansible-galaxy collection install -r ${HOME}/requirements.yml \
 && chmod -R ug+rwx ${HOME}/.ansible

USER 0
RUN pip3 install --upgrade PyMySQL psycopg2-binary
USER 1001

COPY watches.yaml ${HOME}/watches.yaml
COPY roles/ ${HOME}/roles/
