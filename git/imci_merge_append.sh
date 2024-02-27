#!/bin/bash

# append more commits from source branch to target branch
src_br=imci_dev
tgt_br=$(git rev-parse --abbrev-ref HEAD)
ch=imci/imci_commit_history

git fetch origin

echo "Rebasing to latest origin/master commit"
git rebase origin/master

# locate commit startpoint and endpoint
#prev_commit=$(git show | grep "Latest commit in ${src_br}" | awk '{print $NF}')
prev_commit=$(grep '^commit ' ${ch} | head -n1 | awk '{print $2}')
curr_commit=$(git show origin/${src_br} | head -n  1 | awk '{print $2}')

echo "Will cherry-pick commits from ${prev_commit} to ${curr_comit}"
echo -e "`head -n 1 ${ch}`\n\n`git log ${prev_commit}..${curr_commit}`" > imci/temp
sed "1d" ${ch} >> imci/temp
mv imci/temp ${ch}
git add ${ch}
git commit -m "update commit to ${curr_commit}"

git cherry-pick ${prev_commit}..${curr_commit}

# if any conflict happens, please solve it and run git-cherry-pick --continue

