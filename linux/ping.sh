for domain in `cat domain.txt`
do
echo $domain
ping $domain|grep from|head -n 1|awk '{print $4}'
done
