#!/bin/bash

# cherry-pcik commits from source branch to target branch
src_br=imci_dev
tgt_br=${src_br}_merge_$(date +'%Y%m%d')
ch=imci/imci_commit_history

echo "cherry-pick commits from origin/${src_br} to ${tgt_br} for merge"
git fetch origin
# set new branch
git checkout -b ${tgt_br} origin/master
base_commit=$(git show | head -n  1 | awk '{print $2}')
# locate commit start point and endpoint
prev_commit=$(grep 'commit ' ${ch} | head -n 1 | awk '{print $2}')
curr_commit=$(git show origin/${src_br} | head -n  1 | awk '{print $2}')

echo "Will cherry-pick commits from ${prev_commit} to ${curr_commit}"
echo -e "# imci_dev merge `date +'%Y-%m-%d'`\n\n`git log ${prev_commit}..${curr_commit}`\n" > imci/temp
cat ${ch} >> imci/temp
mv imci/temp ${ch}

# git diff origin/master -- ${ch}

git add ${ch}
git commit -m "update commit to ${curr_commit}"
git cherry-pick ${prev_commit}..${curr_commit}

echo "if any conflict happens, please solve it and run git-cherry-pick --continue. After that can merge it base on ${base_commit} with command 'git rebase -i ${base_commit}'"
